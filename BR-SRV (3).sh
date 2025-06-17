#!/bin/bash

# === НАСТРОЙКИ ПО УМОЛЧАНИЮ ===
HOSTNAME="br-srv.au-team.irpo"
SSHUSER="sshuser"
SSHUSER_UID="1010"
SSHUSER_PASS="P@ssw0rd"
TZ="Asia/Novosibirsk"
SSH_PORT="3010"
BANNER="Authorized access only"

# === ФУНКЦИИ ДЛЯ ВВОДА ДАННЫХ ===
function input_menu() {
    while true; do
        clear
        echo "=== Подменю ввода/изменения данных ==="
        echo "1. Изменить имя машины (текущее: $HOSTNAME)"
        echo "2. Изменить порт SSH (текущий: $SSH_PORT)"
        echo "3. Изменить имя пользователя SSH (текущее: $SSHUSER)"
        echo "4. Изменить UID пользователя SSH (текущий: $SSHUSER_UID)"
        echo "5. Изменить пароль пользователя SSH"
        echo "6. Изменить часовой пояс (текущий: $TZ)"
        echo "7. Изменить баннер SSH (текущий: $BANNER)"
        echo "8. Изменить все параметры сразу"
        echo "0. Назад"
        read -p "Выберите пункт: " subchoice
        case "$subchoice" in
            1) read -p "Введите новое имя машины: " HOSTNAME ;;
            2) read -p "Введите новый порт SSH [$SSH_PORT]: " input
               SSH_PORT=${input:-$SSH_PORT} ;;
            3) read -p "Введите новое имя пользователя SSH: " SSHUSER ;;
            4) read -p "Введите новый UID пользователя SSH: " SSHUSER_UID ;;
            5) read -s -p "Введите новый пароль пользователя SSH: " SSHUSER_PASS; echo ;;
            6) read -p "Введите новый часовой пояс: " TZ ;;
            7) read -p "Введите новый баннер SSH: " BANNER ;;
            8)
                read -p "Имя машины: " HOSTNAME
                read -p "Порт SSH: " SSH_PORT
                read -p "Имя пользователя SSH: " SSHUSER
                read -p "UID пользователя SSH: " SSHUSER_UID
                read -s -p "Пароль пользователя SSH: " SSHUSER_PASS; echo
                read -p "Часовой пояс: " TZ
                read -p "Баннер SSH: " BANNER
                ;;
            0) break ;;
            *) echo "Ошибка ввода"; sleep 1 ;;
        esac
    done
}

# === УСТАНОВКА ЗАВИСИМОСТЕЙ ===
function install_deps() {
    apt-get update
    apt-get install -y mc sudo openssh-server
}

# === 1. Смена имени хоста ===
function set_hostname() {
    echo "$HOSTNAME" > /etc/hostname
    hostnamectl set-hostname "$HOSTNAME"
    echo "127.0.0.1   $HOSTNAME" >> /etc/hosts
    echo "Имя хоста установлено: $HOSTNAME"
    sleep 2
}

# === 2. Создание пользователя sshuser ===
function create_sshuser() {
    echo "Создание пользователя $SSHUSER..."
    if id "$SSHUSER" &>/dev/null; then
        echo "Пользователь $SSHUSER уже существует, обновление пароля и прав..."
    else
        useradd -u "$SSHUSER_UID" -m "$SSHUSER" || { echo "Ошибка создания пользователя $SSHUSER"; exit 1; }
    fi
    echo "$SSHUSER:$SSHUSER_PASS" | chpasswd
    usermod -aG wheel "$SSHUSER"
    # Удаляем старую строку в sudoers, если она есть
    sed -i "/^$SSHUSER /d" /etc/sudoers
    # Добавляем новую строку для NOPASSWD
    echo "$SSHUSER ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
    echo "Пользователь $SSHUSER создан с UID $SSHUSER_UID и правами sudo без пароля"
    sleep 2
}

# === 3. Настройка SSH ===
function config_ssh() {
    sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/openssh/sshd_config
    sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" /etc/openssh/sshd_config
    grep -q "^AllowUsers" /etc/openssh/sshd_config && \
        sed -i "s/^AllowUsers .*/AllowUsers $SSHUSER/" /etc/openssh/sshd_config || \
        echo "AllowUsers $SSHUSER" >> /etc/openssh/sshd_config
    sed -i "s/^#*MaxAuthTries .*/MaxAuthTries 2/" /etc/openssh/sshd_config
    echo "$BANNER" > /etc/banner
    grep -q "^Banner" /etc/openssh/sshd_config && \
        sed -i "s|^Banner .*|Banner /etc/banner|" /etc/openssh/sshd_config || \
        echo "Banner /etc/banner" >> /etc/openssh/sshd_config
    systemctl restart sshd
    echo "SSH настроен: порт $SSH_PORT, только $SSHUSER, 2 попытки, баннер"
    sleep 2
}

# === 4. Настройка часового пояса ===
function set_timezone() {
    timedatectl set-timezone "$TZ"
    echo "Часовой пояс установлен: $TZ"
    sleep 2
}

# === 5. Настроить всё сразу ===
function do_all() {
    set_hostname
    create_sshuser
    config_ssh
    set_timezone
    echo "Все задания выполнены!"
    sleep 2
}

# === МЕНЮ ===
function main_menu() {
    while true; do
        clear
        echo "=== МЕНЮ НАСТРОЙКИ BR-SRV ==="
        echo "1. Ввод/изменение данных"
        echo "2. Сменить имя хоста"
        echo "3. Создать пользователя SSH ($SSHUSER)"
        echo "4. Настроить SSH"
        echo "5. Настроить часовой пояс"
        echo "6. Настроить всё сразу"
        echo "0. Выйти"
        read -p "Выберите пункт: " choice
        case "$choice" in
            1) input_menu ;;
            2) set_hostname ;;
            3) create_sshuser ;;
            4) config_ssh ;;
            5) set_timezone ;;
            6) do_all ;;
            0) clear; exit 0 ;;
            *) echo "Ошибка ввода"; sleep 1 ;;
        esac
    done
}

# === ОСНОВНОЙ БЛОК ===
if [ "$EUID" -ne 0 ]; then
    echo "Пожалуйста, запустите скрипт от root"
    exit 1
fi

install_deps
main_menu
