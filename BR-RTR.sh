#!/bin/bash

# Скрипт для настройки BR-RTR

# Установка зависимостей при запуске скрипта
install_dependencies() {
    echo "Установка зависимостей..."
    apt-get update
    apt-get install -y iproute2 nftables systemd frr mc wget openssh-server
    echo "Зависимости установлены."
}

install_dependencies

# Начальные значения переменных (Вариант 7 из Ответы.txt)
INTERFACE_ISP="ens192"
INTERFACE_LAN="ens224"
IP_LAN="10.1.1.1/28"
HOSTNAME="br-rtr.au-team.irpo"
TIME_ZONE="Asia/Novosibirsk"
USERNAME="net_admin"
USER_UID=1010
BANNER_TEXT="Authorized access only"
TUNNEL_LOCAL_IP="172.16.50.2"  # IP BR-RTR к провайдеру
TUNNEL_REMOTE_IP="172.16.40.2" # IP HQ-RTR к провайдеру
TUNNEL_IP="172.16.100.2/28"   # IP туннеля для BR-RTR
TUNNEL_NAME="tun1"

# Функция проверки существования интерфейса
check_interface() {
    if ! ip link show "$1" &> /dev/null; then
        echo "Ошибка: Интерфейс $1 не существует."
        exit 1
    fi
}

# Функция вычисления сети из IP и маски
get_network() {
    local ip_mask=$1
    local ip=$(echo "$ip_mask" | cut -d'/' -f1)
    local mask=$(echo "$ip_mask" | cut -d'/' -f2)
    local IFS='.'
    read -r i1 i2 i3 i4 <<< "$ip"
    local bits=$((32 - mask))
    local net=$(( (i1 << 24) + (i2 << 16) + (i3 << 8) + i4 ))
    local net=$(( net >> bits << bits ))
    echo "$(( (net >> 24) & 255 )).$(( (net >> 16) & 255 )).$(( (net >> 8) & 255 )).$(( net & 255 ))/$mask"
}

# Функция настройки сетевых интерфейсов через /etc/net/ifaces/
configure_interfaces() {
    echo "Настройка интерфейсов через /etc/net/ifaces/..."
    
    check_interface "$INTERFACE_ISP"
    check_interface "$INTERFACE_LAN"
    
    mkdir -p /etc/net/ifaces/"$INTERFACE_ISP"
    cat > /etc/net/ifaces/"$INTERFACE_ISP"/options << EOF
BOOTPROTO=static
TYPE=eth
DISABLED=no
CONFIG_IPV4=yes
EOF
    
    mkdir -p /etc/net/ifaces/"$INTERFACE_LAN"
    cat > /etc/net/ifaces/"$INTERFACE_LAN"/options << EOF
BOOTPROTO=static
TYPE=eth
DISABLED=no
CONFIG_IPV4=yes
EOF
    echo "$IP_LAN" > /etc/net/ifaces/"$INTERFACE_LAN"/ipv4address
    
    systemctl restart network
    echo "Интерфейсы настроены."
}

# Функция настройки GRE-туннеля через /etc/net/ifaces/
configure_tunnel() {
    echo "Настройка GRE-туннеля через /etc/net/ifaces/..."
    
    modprobe gre
    
    mkdir -p /etc/net/ifaces/"$TUNNEL_NAME"
    cat > /etc/net/ifaces/"$TUNNEL_NAME"/options << EOF
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=$TUNNEL_LOCAL_IP
TUNREMOTE=$TUNNEL_REMOTE_IP
TUNOPTIONS='ttl 64'
HOST=$INTERFACE_ISP
BOOTPROTO=static
DISABLED=no
CONFIG_IPV4=yes
EOF
    echo "$TUNNEL_IP" > /etc/net/ifaces/"$TUNNEL_NAME"/ipv4address
    
    ip link set "$TUNNEL_NAME" down 2>/dev/null || true
    ip tunnel del "$TUNNEL_NAME" 2>/dev/null || true
    ip tunnel add "$TUNNEL_NAME" mode gre local "$TUNNEL_LOCAL_IP" remote "$TUNNEL_REMOTE_IP" ttl 64
    ip addr add "$TUNNEL_IP" dev "$TUNNEL_NAME"
    ip link set "$TUNNEL_NAME" up
    
    systemctl restart network
    echo "GRE-туннель настроен."
}

# Функция настройки nftables и пересылки IP
configure_nftables() {
    echo "Настройка nftables и пересылки IP..."
    
    apt-get install -y nftables
    
    LAN_NETWORK=$(get_network "$IP_LAN")
    
    sysctl -w net.ipv4.ip_forward=1
    if grep -q "net.ipv4.ip_forward" /etc/net/sysctl.conf; then
        sed -i 's/net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/net/sysctl.conf
    else
        echo "net.ipv4.ip_forward=1" >> /etc/net/sysctl.conf
    fi
    
    cat > /etc/nftables/nftables.nft << EOF
#!/usr/sbin/nft -f
flush ruleset

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 0; policy accept;
        ip saddr $LAN_NETWORK oifname "$INTERFACE_ISP" counter masquerade
    }
}
EOF
    
    nft -f /etc/nftables/nftables.nft
    systemctl enable --now nftables
    echo "nftables и пересылка IP настроены."
}

# Функция установки имени хоста
set_hostname() {
    echo "Установка имени хоста..."
    hostnamectl set-hostname "$HOSTNAME"
    echo "$HOSTNAME" > /etc/hostname
    echo "Имя хоста установлено: $HOSTNAME"
}

# Функция установки часового пояса
set_timezone() {
    echo "Установка часового пояса..."
    apt-get install -y tzdata
    timedatectl set-timezone "$TIME_ZONE"
    echo "Часовой пояс установлен: $TIME_ZONE"
}

# Функция настройки пользователя
configure_user() {
    echo "Настройка пользователя..."
    if [ -z "$USER_UID" ]; then
        read -p "Введите UID для пользователя $USERNAME: " USER_UID
    fi
    if adduser --uid "$USER_UID" "$USERNAME"; then
        read -s -p "Введите пароль для пользователя $USERNAME: " PASSWORD
        echo
        echo "$USERNAME:$PASSWORD" | chpasswd
        echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
        usermod -aG wheel "$USERNAME"
        echo "Пользователь $USERNAME создан с UID $USER_UID и правами sudo."
    else
        echo "Ошибка: Не удалось создать пользователя $USERNAME."
        exit 1
    fi
}

# Функция настройки баннера SSH
configure_ssh_banner() {
    echo "Настройка баннера SSH..."
    echo "$BANNER_TEXT" > /etc/banner
    if grep -q "^Banner" /etc/openssh/sshd_config; then
        sed -i 's|^Banner.*|Banner /etc/banner|' /etc/openssh/sshd_config
    else
        echo "Banner /etc/banner" >> /etc/openssh/sshd_config
    fi
    systemctl restart sshd
    echo "Баннер SSH настроен."
}

# Функция настройки OSPF
configure_ospf() {
    echo "Настройка OSPF..."
    
    TUNNEL_NETWORK=$(get_network "$TUNNEL_IP")
    LAN_NETWORK=$(get_network "$IP_LAN")
    
    if grep -q "ospfd=no" /etc/frr/daemons; then
        sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    elif ! grep -q "ospfd=yes" /etc/frr/daemons; then
        echo "ospfd=yes" >> /etc/frr/daemons
    fi
    systemctl enable --now frr
    
    vtysh << EOF
configure terminal
router ospf
passive-interface default
network $TUNNEL_NETWORK area 0
network $LAN_NETWORK area 0
exit
interface $TUNNEL_NAME
no ip ospf passive
ip ospf authentication-key PLAINPAS
ip ospf authentication
exit
do wr mem
exit
EOF
    
    systemctl restart network
    echo "OSPF настроен."
}

# Функция редактирования данных
edit_data() {
    while true; do
        clear
        echo "Текущие значения:"
        echo "1. Интерфейс ISP: $INTERFACE_ISP"
        echo "2. Интерфейс LAN: $INTERFACE_LAN"
        echo "3. IP LAN: $IP_LAN"
        echo "4. Локальный IP туннеля: $TUNNEL_LOCAL_IP"
        echo "5. Имя хоста: $HOSTNAME"
        echo "6. Часовой пояс: $TIME_ZONE"
        echo "7. Имя пользователя: $USERNAME"
        echo "8. UID пользователя: $USER_UID"
        echo "9. Текст баннера: $BANNER_TEXT"
        echo "10. Удаленный IP туннеля: $TUNNEL_REMOTE_IP"
        echo "11. IP туннеля: $TUNNEL_IP"
        echo "0. Назад"
        read -p "Введите номер параметра для изменения: " choice
        case $choice in
            1) read -p "Новый интерфейс ISP [$INTERFACE_ISP]: " input
               INTERFACE_ISP=${input:-$INTERFACE_ISP} ;;
            2) read -p "Новый интерфейс LAN [$INTERFACE_LAN]: " input
               INTERFACE_LAN=${input:-$INTERFACE_LAN} ;;
            3) read -p "Новый IP LAN [$IP_LAN]: " input
               IP_LAN=${input:-$IP_LAN} ;;
            4) read -p "Новый локальный IP туннеля [$TUNNEL_LOCAL_IP]: " input
               TUNNEL_LOCAL_IP=${input:-$TUNNEL_LOCAL_IP} ;;
            5) read -p "Новое имя хоста [$HOSTNAME]: " input
               HOSTNAME=${input:-$HOSTNAME} ;;
            6) read -p "Новый часовой пояс [$TIME_ZONE]: " input
               TIME_ZONE=${input:-$TIME_ZONE} ;;
            7) read -p "Новое имя пользователя [$USERNAME]: " input
               USERNAME=${input:-$USERNAME} ;;
            8) read -p "Новый UID пользователя [$USER_UID]: " input
               USER_UID=${input:-$USER_UID} ;;
            9) read -p "Новый текст баннера [$BANNER_TEXT]: " input
               BANNER_TEXT=${input:-$BANNER_TEXT} ;;
            10) read -p "Новый удаленный IP туннеля [$TUNNEL_REMOTE_IP]: " input
                TUNNEL_REMOTE_IP=${input:-$TUNNEL_REMOTE_IP} ;;
            11) read -p "Новый IP туннеля [$TUNNEL_IP]: " input
                TUNNEL_IP=${input:-$TUNNEL_IP} ;;
            0) return ;;
            *) echo "Неверный выбор." ;;
        esac
    done
}

# Главное меню
while true; do
    clear
    echo -e "\nМеню настройки BR-RTR:"
    echo "1. Редактировать данные"
    echo "2. Настроить сетевые интерфейсы"
    echo "3. Настроить NAT и пересылку IP"
    echo "4. Настроить GRE-туннель"
    echo "5. Настроить OSPF"
    echo "6. Установить имя хоста"
    echo "7. Установить часовой пояс"
    echo "8. Настроить пользователя"
    echo "9. Настроить баннер SSH"
    echo "10. Выполнить все настройки"
    echo "0. Выход"
    read -p "Выберите опцию: " option
    
    case $option in
        1) edit_data ;;
        2) configure_interfaces ;;
        3) configure_nftables ;;
        4) configure_tunnel ;;
        5) configure_ospf ;;
        6) set_hostname ;;
        7) set_timezone ;;
        8) configure_user ;;
        9) configure_ssh_banner ;;
        10) 
            configure_interfaces
            configure_nftables
            configure_tunnel
            configure_ospf
            set_hostname
            set_timezone
            configure_user
            configure_ssh_banner
            echo "Все настройки завершены."
            ;;
        0) echo "Выход."; exit 0 ;;
        *) echo "Неверный выбор." ;;
    esac
done
