#!/bin/bash

# Скрипт настройки ISP
# Обрабатывает ввод данных и выполняет базовые задачи конфигурации.
# Логи записываются в /var/log/isp_config.log.

# Проверка запуска от имени root
if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: Этот скрипт должен быть запущен от имени root." >&2
    exit 1
fi

# Файл логов
LOG_FILE="/var/log/isp_config.log"

# Функция логирования
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOG_FILE"
    echo "$1"
}

# Инициализация файла логов
if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE" 2>/dev/null || { echo "Ошибка: Не удалось создать файл логов в $LOG_FILE." >&2; exit 1; }
fi
chmod 644 "$LOG_FILE" 2>/dev/null || { echo "Ошибка: Не удалось установить права на файл логов." >&2; exit 1; }

log_message "Запуск скрипта настройки ISP..."

# Проверка и установка необходимых команд
check_and_install_command() {
    local cmd=$1
    local pkg=$2
    if ! command -v "$cmd" &>/dev/null; then
        log_message "Ошибка: Команда '$cmd' не найдена. Попытка установить пакет '$pkg'..."
        if ! apt-get update >> "$LOG_FILE" 2>&1; then
            log_message "Предупреждение: Не удалось обновить списки пакетов. Проверьте конфигурацию репозиториев."
            read -p "Нажмите Enter после ручной установки $pkg или выйдите (Ctrl+C)..."
        else
            if ! apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1; then
                log_message "Ошибка: Не удалось установить $pkg. Установите вручную: 'sudo apt-get install $pkg'."
                read -p "Нажмите Enter после ручной установки $pkg или выйдите (Ctrl+C)..."
            else
                log_message "Пакет '$pkg' успешно установлен."
                export PATH=$PATH:/usr/sbin:/usr/local/sbin
                if ! command -v "$cmd" &>/dev/null; then
                    log_message "Ошибка: Команда '$cmd' не найдена после установки. Проверьте PATH."
                    read -p "Нажмите Enter после исправления PATH или ручной установки..."
                fi
            fi
        fi
    fi
}

# Проверка необходимых команд и пакетов
check_and_install_command "apt-get" "apt"
check_and_install_command "timedatectl" "systemd"
check_and_install_command "systemctl" "systemd"
check_and_install_command "nft" "nftables"
check_and_install_command "ip" "iproute2"
check_and_install_command "locale-gen" "locales"

# Проверка и установка tzdata
set_timezone() {
    echo "Установка часового пояса..."
    apt-get install -y tzdata
    timedatectl set-timezone "$TIME_ZONE"
    echo "Часовой пояс установлен: $TIME_ZONE"
}
set_timezone
# Настройка русского языка
configure_russian_locale() {
    log_message "Проверка русского языка (ru_RU.UTF-8)..."
    if ! locale -a | grep -q "ru_RU.utf8"; then
        log_message "Русский язык не найден. Установка и генерация..."
        apt-get update >> "$LOG_FILE" 2>&1 || { log_message "Предупреждение: Не удалось обновить списки пакетов."; return 1; }
        apt-get install -y locales >> "$LOG_FILE" 2>&1 || { log_message "Ошибка: Не удалось установить пакет locales."; return 1; }
        echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen 2>>"$LOG_FILE" || { log_message "Ошибка: Не удалось обновить /etc/locale.gen."; return 1; }
        locale-gen ru_RU.UTF-8 >> "$LOG_FILE" 2>&1 || { log_message "Ошибка: Не удалось сгенерировать ru_RU.UTF-8."; return 1; }
        update-locale LANG=ru_RU.UTF-8 >> "$LOG_FILE" 2>&1 || { log_message "Ошибка: Не удалось установить LANG=ru_RU.UTF-8."; return 1; }
        log_message "Русский язык (ru_RU.UTF-8) настроен."
    else
        log_message "Русский язык (ru_RU.UTF-8) уже настроен."
    fi
}

# Валидация IP-адреса
validate_ip() {
    local ip_with_mask=$1
    if [[ $ip_with_mask =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        local ip=$(echo "$ip_with_mask" | cut -d'/' -f1)
        local prefix=$(echo "$ip_with_mask" | cut -d'/' -f2)
        if [[ $ip =~ ^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]] && [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ]; then
            return 0
        fi
    fi
    return 1
}

# Проверка часового пояса
check_timezone() {
    local tz=$1
    if ! timedatectl list-timezones > /tmp/tzlist.log 2>>"$LOG_FILE"; then
        log_message "Ошибка: Не удалось получить список часовых поясов."
        return 1
    fi
    if grep -Fxq "$tz" /tmp/tzlist.log; then
        rm -f /tmp/tzlist.log
        return 0
    else
        rm -f /tmp/tzlist.log
        return 1
    fi
}

# Расчет сетевого адреса
get_network() {
    local ip_with_mask=$1
    if ! [[ $ip_with_mask =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; then
        log_message "Ошибка: Неверный формат IP: $ip_with_mask"
        return 1
    fi
    local ip=$(echo "$ip_with_mask" | cut -d'/' -f1)
    local prefix=$(echo "$ip_with_mask" | cut -d'/' -f2)
    if [ "$prefix" -lt 0 ] || [ "$prefix" -gt 32 ]; then
        log_message "Ошибка: Неверный префикс: $prefix (должен быть 0-32)"
        return 1
    fi
    IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$ip"
    for oct in $oct1 $oct2 $oct3 $oct4; do
        if [ "$oct" -lt 0 ] || [ "$oct" -gt 255 ]; then
            log_message "Ошибка: Неверный октет: $oct (должен быть 0-255)"
            return 1
        fi
    done
    local ip_num=$(( (oct1 << 24) + (oct2 << 16) + (oct3 << 8) + oct4 ))
    local bits=$((32 - prefix))
    local mask=$(( (0xffffffff << bits) & 0xffffffff ))
    local net_num=$((ip_num & mask))
    local net_oct1=$(( (net_num >> 24) & 0xff ))
    local net_oct2=$(( (net_num >> 16) & 0xff ))
    local net_oct3=$(( (net_num >> 8) & 0xff ))
    local net_oct4=$(( net_num & 0xff ))
    echo "${net_oct1}.${net_oct2}.${net_oct3}.${net_oct4}/${prefix}"
}

# Значения по умолчанию
INTERFACE_HQ="ens256"
INTERFACE_BR="ens224"
INTERFACE_OUT="ens192"
IP_HQ="172.16.40.1/28"
IP_BR="172.16.50.1/28"
HOSTNAME="isp"
TIME_ZONE="Asia/Novosibirsk"

# Отображение меню
display_menu() {
    clear
    echo "---------------------"
    echo "Меню настройки ISP"
    echo "---------------------"
    echo "1. Ввести или редактировать данные"
    echo "2. Настроить сетевые интерфейсы"
    echo "3. Настроить nftables (NAT)"
    echo "4. Установить имя хоста"
    echo "5. Установить часовой пояс на Asia/Novosibirsk"
    echo "6. Настроить всё"
    echo "0. Выход"
}

# Редактирование данных
edit_data() {
    while true; do
        clear
        echo "Текущие данные:"
        echo "1. Интерфейс HQ: ${INTERFACE_HQ:-Не установлен}"
        echo "2. Интерфейс BR: ${INTERFACE_BR:-Не установлен}"
        echo "3. Интерфейс для выхода в интернет: ${INTERFACE_OUT:-Не установлен}"
        echo "4. IP для HQ: ${IP_HQ:-Не установлен}"
        echo "5. IP для BR: ${IP_BR:-Не установлен}"
        echo "6. Имя хоста: ${HOSTNAME:-Не установлено}"
        echo "7. Установить часовой пояс"
        echo "8. Ввести все данные заново"
        echo "9. Настроить русский язык"
        echo "0. Выйти"
        read -p "Выберите опцию: " choice
        case $choice in
            1) read -p "Введите имя интерфейса HQ: " INTERFACE_HQ ;;
            2) read -p "Введите имя интерфейса BR: " INTERFACE_BR ;;
            3) read -p "Введите имя интерфейса для выхода в интернет: " INTERFACE_OUT ;;
            4)
                while true; do
                    read -p "Введите IP для HQ (например, 172.16.4.1/28): " IP_HQ
                    if validate_ip "$IP_HQ"; then break; else
                        echo "Неверный формат IP. Используйте формат, например, 172.16.4.1/28."
                        read -p "Нажмите Enter, чтобы попробовать снова..."
                    fi
                done
                ;;
            5)
                while true; do
                    read -p "Введите IP для BR (например, 172.16.5.1/28): " IP_BR
                    if validate_ip "$IP_BR"; then break; else
                        echo "Неверный формат IP. Используйте формат, например, 172.16.5.1/28."
                        read -p "Нажмите Enter, чтобы попробовать снова..."
                    fi
                done
                ;;
            6) read -p "Введите имя хоста: " HOSTNAME ;;
            7)
                while true; do
                        echo "Установка часового пояса..."
                        apt-get install -y tzdata
                        timedatectl set-timezone "$TIME_ZONE"
                        echo "Часовой пояс установлен: $TIME_ZONE"
                done
                ;;
            8)
                read -p "Введите имя интерфейса HQ: " INTERFACE_HQ
                read -p "Введите имя интерфейса BR: " INTERFACE_BR
                read -p "Введите имя интерфейса для выхода в интернет: " INTERFACE_OUT
                while true; do
                    read -p "Введите IP для HQ (например, 172.16.4.1/28): " IP_HQ
                    if validate_ip "$IP_HQ"; then break; else
                        echo "Неверный формат IP. Используйте формат, например, 172.16.4.1/28."
                        read -p "Нажмите Enter, чтобы попробовать снова..."
                    fi
                done
                while true; do
                    read -p "Введите IP для BR (например, 172.16.5.1/28): " IP_BR
                    if validate_ip "$IP_BR"; then break; else
                        echo "Неверный формат IP. Используйте формат, например, 172.16.5.1/28."
                        read -p "Нажмите Enter, чтобы попробовать снова..."
                    fi
                done
                read -p "Введите имя хоста: " HOSTNAME
                ;;
            9) configure_russian_locale ;;
            0) break ;;
            *) echo "Неверный выбор."; read -p "Нажмите Enter, чтобы продолжить..." ;;
        esac
    done
}

# Настройка сетевых интерфейсов
configure_interfaces() {
    if [ -z "$IP_HQ" ] || [ -z "$IP_BR" ] || [ -z "$INTERFACE_HQ" ] || [ -z "$INTERFACE_BR" ]; then
        log_message "Ошибка: Имена интерфейсов или IP-адреса не заданы. Установите их в пункте 1."
        read -p "Нажмите Enter, чтобы продолжить..."
        return 1
    fi

    for iface in "$INTERFACE_HQ" "$INTERFACE_BR" "$INTERFACE_OUT"; do
        if ! ip link show "$iface" &>/dev/null; then
            log_message "Ошибка: Интерфейс $iface не существует."
            read -p "Нажмите Enter, чтобы продолжить..."
            return 1
        fi
        if [ -d "/etc/net/ifaces/$iface" ]; then
            read -p "Конфигурация для $iface существует. Перезаписать? (y/n): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                log_message "Пропуск конфигурации интерфейса $iface."
                continue
            fi
        fi
    done

    for iface in "$INTERFACE_HQ" "$INTERFACE_BR"; do
        mkdir -p "/etc/net/ifaces/$iface" >> "$LOG_FILE" 2>&1 || { log_message "Ошибка: Не удалось создать директорию для $iface."; return 1; }
        echo -e "BOOTPROTO=static\nTYPE=eth\nDISABLED=no\nCONFIG_IPV4=yes" > "/etc/net/ifaces/$iface/options" 2>>"$LOG_FILE" || { log_message "Ошибка: Не удалось записать настройки для $iface."; return 1; }
        if [ "$iface" = "$INTERFACE_HQ" ]; then
            echo "$IP_HQ" > "/etc/net/ifaces/$iface/ipv4address" 2>>"$LOG_FILE" || { log_message "Ошибка: Не удалось установить IP для $iface."; return 1; }
        elif [ "$iface" = "$INTERFACE_BR" ]; then
            echo "$IP_BR" > "/etc/net/ifaces/$iface/ipv4address" 2>>"$LOG_FILE" || { log_message "Ошибка: Не удалось установить IP для $iface."; return 1; }
        fi
    done

    systemctl restart network >> "$LOG_FILE" 2>&1 || { log_message "Ошибка: Не удалось перезапустить сетевой сервис."; return 1; }
    log_message "Интерфейсы $INTERFACE_HQ и $INTERFACE_BR настроены."
    read -p "Нажмите Enter, чтобы продолжить..."
}

# Включение IP-пересылки
enable_ip_forwarding() {
    local current_forwarding=$(sysctl -n net.ipv4.ip_forward)
    if [ "$current_forwarding" -eq 0 ]; then
        log_message "IP-пересылка отключена. Включение временно и постоянно..."
        echo 1 > /proc/sys/net/ipv4/ip_forward 2>>"$LOG_FILE" || { log_message "Ошибка: Не удалось включить IP-пересылку временно."; return 1; }
        if grep -q "^net.ipv4.ip_forward" /etc/net/sysctl.conf; then
            sed -i '/^net.ipv4.ip_forward/c\net.ipv4.ip_forward = 1' /etc/net/sysctl.conf 2>>"$LOG_FILE" || { log_message "Ошибка: Не удалось изменить sysctl.conf."; return 1; }
        elif grep -q "^#net.ipv4.ip_forward" /etc/net/sysctl.conf; then
            sed -i 's/^#net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf 2>>"$LOG_FILE" || { log_message "Ошибка: Не удалось изменить sysctl.conf."; return 1; }
        else
            echo "net.ipv4.ip_forward = 1" >> /etc/net/sysctl.conf 2>>"$LOG_FILE" || { log_message "Ошибка: Не удалось добавить в sysctl.conf."; return 1; }
        fi
        sysctl -p >> "$LOG_FILE" 2>&1 || { log_message "Ошибка: Не удалось применить настройки sysctl."; return 1; }
        log_message "IP-пересылка включена."
    else
        log_message "IP-пересылка уже включена."
    fi
}

# Настройка nftables
configure_nftables() {
    if [ -z "$IP_HQ" ] || [ -z "$IP_BR" ] || [ -z "$INTERFACE_OUT" ]; then
        log_message "Ошибка: IP-адреса или исходящий интерфейс не заданы. Установите их в пункте 1."
        read -p "Нажмите Enter, чтобы продолжить..."
        return 1
    fi

    if ! ip link show "$INTERFACE_OUT" &>/dev/null; then
        log_message "Ошибка: Исходящий интерфейс $INTERFACE_OUT не существует."
        read -p "Нажмите Enter, чтобы продолжить..."
        return 1
    fi

    enable_ip_forwarding || return 1

    HQ_NETWORK=$(get_network "$IP_HQ") || { log_message "Ошибка: Не удалось вычислить сеть HQ."; return 1; }
    BR_NETWORK=$(get_network "$IP_BR") || { log_message "Ошибка: Не удалось вычислить сеть BR."; return 1; }
    log_message "Сеть HQ: $HQ_NETWORK"
    log_message "Сеть BR: $BR_NETWORK"

    read -p "Продолжить настройку nftables? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_message "Настройка nftables пропущена."
        read -p "Нажмите Enter, чтобы продолжить..."
        return 0
    fi

    systemctl enable --now nftables >> "$LOG_FILE" 2>&1 || { log_message "Ошибка: Не удалось включить или запустить nftables."; return 1; }
    mkdir -p /etc/nftables >> "$LOG_FILE" 2>&1 || { log_message "Ошибка: Не удалось создать директорию /etc/nftables."; return 1; }

    cat > /etc/nftables/nftables.nft 2>>"$LOG_FILE" << EOF || { log_message "Ошибка: Не удалось записать в /etc/nftables/nftables.nft."; return 1; }
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 0; policy accept;
        ip saddr $HQ_NETWORK oifname "$INTERFACE_OUT" counter masquerade
        ip saddr $BR_NETWORK oifname "$INTERFACE_OUT" counter masquerade
    }
}
EOF

    chmod 644 /etc/nftables/nftables.nft 2>>"$LOG_FILE" || { log_message "Ошибка: Не удалось установить права на /etc/nftables/nftables.nft."; return 1; }
    systemctl restart nftables >> "$LOG_FILE" 2>&1 || { log_message "Ошибка: Не удалось перезапустить nftables."; return 1; }
    log_message "nftables настроены через /etc/nftables/nftables.nft."
    read -p "Нажмите Enter, чтобы продолжить..."
}

# Установка имени хоста
set_hostname() {
    if [ -z "$HOSTNAME" ]; then
        log_message "Ошибка: Имя хоста не задано. Установите его в пункте 1."
        read -p "Нажмите Enter, чтобы продолжить..."
        return 1
    fi
    echo "$HOSTNAME" > /etc/hostname 2>>"$LOG_FILE" || { log_message "Ошибка: Не удалось записать в /etc/hostname."; return 1; }
    hostnamectl set-hostname "$HOSTNAME" >> "$LOG_FILE" 2>&1 || { log_message "Ошибка: Не удалось установить имя хоста."; return 1; }
    log_message "Имя хоста установлено: $HOSTNAME."
    read -p "Нажмите Enter, чтобы продолжить..."
}

# Установка часового пояса на Asia/Novosibirsk
set_timezone_novosibirsk() {
    local tz="Asia/Novosibirsk"
    if check_timezone "$tz"; then
        timedatectl set-timezone "$tz" >> "$LOG_FILE" 2>&1 || { log_message "Ошибка: Не удалось установить часовой пояс $tz."; return 1; }
        TIME_ZONE="$tz"
        log_message "Часовой пояс установлен на $tz. Проверьте лог для подробностей."
    else
        log_message "Ошибка: Часовой пояс $tz неверный. Используйте 'timedatectl list-timezones' для списка."
    fi
    read -p "Нажмите Enter, чтобы продолжить..."
}

# Настройка всех параметров
configure_all() {
    log_message "Начало полной настройки..."
    configure_russian_locale || { log_message "Не удалось настроить русский язык."; read -p "Нажмите Enter..."; return 1; }
    configure_interfaces || { log_message "Не удалось настроить сетевые интерфейсы."; read -p "Нажмите Enter..."; return 1; }
    configure_nftables || { log_message "Не удалось настроить nftables."; read -p "Нажмите Enter..."; return 1; }
    set_hostname || { log_message "Не удалось установить имя хоста."; read -p "Нажмите Enter..."; return 1; }
    set_timezone_novosibirsk || { log_message "Не удалось установить часовой пояс."; read -p "Нажмите Enter..."; return 1; }
    log_message "Все настройки успешно завершены."
    read -p "Нажмите Enter, чтобы продолжить..."
}

# Главный цикл
configure_russian_locale
while true; do
    display_menu
    read -p "Введите ваш выбор: " choice
    case $choice in
        1) edit_data ;;
        2) configure_interfaces ;;
        3) configure_nftables ;;
        4) set_hostname ;;
        5) set_timezone_novosibirsk ;;
        6) configure_all ;;
        0) log_message "Выход из скрипта настройки ISP."; clear; exit 0 ;;
        *) echo "Неверный выбор."; read -p "Нажмите Enter, чтобы продолжить..." ;;
    esac
done
