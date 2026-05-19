#!/bin/bash
# TrustTunnel Auto-Setup Script with Let's Encrypt Auto-Renewal
# + Auto-Update TrustTunnel + Multi-User Support
# Requirements: Ubuntu/Debian, root access, domain pointing to this server, port 80/443 open

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TT_DIR="/opt/trusttunnel"
BACKUP_DIR="/opt/trusttunnel/backups"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/TrustTunnel/TrustTunnel/refs/heads/master/scripts/install.sh"
INSTALL_SCRIPT_SHA256_URL="${INSTALL_SCRIPT_URL}.sha256"
UPDATE_CHECK_FILE="${TT_DIR}/.last_install_sha256"

declare -a USERNAMES
declare -a PASSWORDS
declare -a CLIENT_NAMES

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Этот скрипт нужно запускать от root (sudo su)"
        exit 1
    fi
}

check_tty() {
    if [ ! -t 0 ]; then
        log_error "Этот скрипт требует интерактивный терминал (TTY)"
        exit 1
    fi
}

# ===========================
# 1. INSTALL DEPENDENCIES
# ===========================
install_deps() {
    log_info "Обновляем пакеты и ставим зависимости..."

    local deps="curl wget tar certbot bc qrencode dnsutils lsof iptables-persistent jq util-linux"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $deps 2>/dev/null || {
        log_warn "Не удалось установить некоторые пакеты, пробуем по одному..."
        for pkg in $deps; do
            apt-get install -y -qq "$pkg" 2>/dev/null || log_warn "Пакет $pkg не установлен"
        done
    }

    for cmd in certbot qrencode dig lsof curl; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Необходимая утилита $cmd не найдена после установки зависимостей"
            exit 1
        fi
    done
}

# ===========================
# 2. INSTALL TRUSTTUNNEL
# ===========================
install_trusttunnel() {
    if [ -f "${TT_DIR}/trusttunnel_endpoint" ]; then
        log_warn "TrustTunnel уже установлен в ${TT_DIR}"
        read -rp "Переустановить/обновить? [y/N]: " reinstall
        if [[ "$reinstall" =~ ^[Yy]$ ]]; then
            systemctl stop trusttunnel 2>/dev/null || true
            rm -rf "${TT_DIR}"
        else
            log_info "Пропускаем установку TrustTunnel"
            return
        fi
    fi

    log_info "Скачиваем инсталлятор TrustTunnel..."
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    curl -fsSL -o "${tmpdir}/install.sh" "$INSTALL_SCRIPT_URL"

    if curl -fsSL -o "${tmpdir}/install.sh.sha256" "$INSTALL_SCRIPT_SHA256_URL" 2>/dev/null; then
        local expected_sha
        expected_sha=$(awk '{print $1}' "${tmpdir}/install.sh.sha256")
        local actual_sha
        actual_sha=$(sha256sum "${tmpdir}/install.sh" | awk '{print $1}')
        if [ "$expected_sha" != "$actual_sha" ]; then
            log_error "SHA256 checksum инсталлятора не совпадает! Возможна подмена."
            log_error "Ожидаемый: $expected_sha"
            log_error "Фактический: $actual_sha"
            rm -rf "$tmpdir"
            exit 1
        fi
        log_info "Checksum инсталлятора проверен"
        echo "$expected_sha" > "$UPDATE_CHECK_FILE"
    else
        log_warn "Не удалось скачать SHA256 checksum. Проверка целостности пропущена."
        read -rp "Продолжить без проверки? [y/N]: " skip_checksum
        if [[ ! "$skip_checksum" =~ ^[Yy]$ ]]; then
            rm -rf "$tmpdir"
            exit 1
        fi
    fi

    log_info "Запускаем инсталлятор TrustTunnel..."
    sh "${tmpdir}/install.sh"

    rm -rf "$tmpdir"
    trap - EXIT

    if [ ! -f "${TT_DIR}/trusttunnel_endpoint" ]; then
        log_error "Не удалось установить TrustTunnel"
        exit 1
    fi
    log_info "TrustTunnel установлен"
}

# ===========================
# 3. GET USER INPUT
# ===========================
get_user_input() {
    echo ""
    echo "=========================================="
    echo "  НАСТРОЙКА TRUSTTUNNEL + LET'S ENCRYPT"
    echo "=========================================="
    echo ""

    while true; do
        read -rp "Введите ваш домен (должен указывать на этот сервер): " DOMAIN
        if [ -z "$DOMAIN" ]; then
            log_error "Домен не может быть пустым"
            continue
        fi
        break
    done

    log_info "Проверяем разрешение домена..."
    DOMAIN_IP=$(dig +short "$DOMAIN" 2>/dev/null | tail -1 || echo "")
    SERVER_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')

    if [ -n "$DOMAIN_IP" ] && [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
        log_warn "Домен $DOMAIN разрешается в IP: $DOMAIN_IP, но IP этого сервера: $SERVER_IP"
        read -rp "Продолжить anyway? [y/N]: " force_continue
        if [[ ! "$force_continue" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    # --- МНОЖЕСТВЕННЫЕ ПОЛЬЗОВАТЕЛИ ---
    read -rp "Количество пользователей VPN [1]: " USER_COUNT
    USER_COUNT=${USER_COUNT:-1}
    if ! [[ "$USER_COUNT" =~ ^[0-9]+$ ]] || [ "$USER_COUNT" -lt 1 ]; then
        USER_COUNT=1
    fi

    USERNAMES=()
    PASSWORDS=()
    CLIENT_NAMES=()

    for i in $(seq 1 "$USER_COUNT"); do
        echo ""
        echo "--- Пользователь #$i ---"
        local username password client_name
        while true; do
            read -rp "Имя пользователя #$i [user$i]: " username
            username=${username:-user$i}
            if [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                log_error "Имя пользователя может содержать только буквы, цифры, _ и -"
                continue
            fi
            break
        done

        read -rsp "Пароль пользователя #$i (Enter для случайного): " password
        echo ""
        if [ -z "$password" ]; then
            password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
            echo -e "${GREEN}[INFO]${NC} Сгенерирован случайный пароль для $username: $password" > /dev/tty
        fi

        read -rp "Имя клиентской конфигурации #$i [client$i]: " client_name
        client_name=${client_name:-client$i}
        if [[ ! "$client_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log_warn "Имя клиентской конфигурации содержит недопустимые символы, используем client$i"
            client_name="client$i"
        fi

        USERNAMES+=("$username")
        PASSWORDS+=("$password")
        CLIENT_NAMES+=("$client_name")
    done

    while true; do
        read -rp "Порт для TrustTunnel [443]: " LISTEN_PORT
        LISTEN_PORT=${LISTEN_PORT:-443}
        if ! [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || [ "$LISTEN_PORT" -lt 1 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
            log_error "Порт должен быть числом от 1 до 65535"
            continue
        fi
        break
    done
}

# ===========================
# 4. GENERATE CONFIGS
# ===========================
generate_configs() {
    log_info "Генерируем конфигурацию..."

    mkdir -p "${TT_DIR}" "${BACKUP_DIR}"

    for f in credentials.toml rules.toml vpn.toml hosts.toml; do
        if [ -f "${TT_DIR}/${f}" ]; then
            local ts
            ts=$(date +%Y%m%d%H%M%S)
            cp "${TT_DIR}/${f}" "${BACKUP_DIR}/${f}.${ts}"
            log_info "Бэкап ${f} сохранён в ${BACKUP_DIR}/${f}.${ts}"
        fi
    done

    pushd "${TT_DIR}" > /dev/null

    # Генерация credentials.toml с несколькими пользователями
    > credentials.toml
    for idx in "${!USERNAMES[@]}"; do
        cat >> credentials.toml << EOF
[[client]]
username = "${USERNAMES[$idx]}"
password = "${PASSWORDS[$idx]}"

EOF
    done
    chmod 600 credentials.toml

    if [ "$(stat -c '%a' credentials.toml 2>/dev/null || stat -f '%Lp' credentials.toml 2>/dev/null)" != "600" ]; then
        log_warn "Не удалось установить права 600 на credentials.toml"
    fi

    cat > rules.toml << 'EOF'
EOF

    cat > vpn.toml << EOF
listen_address = "0.0.0.0:$LISTEN_PORT"
credentials_file = "credentials.toml"
rules_file = "rules.toml"
ipv6_available = true
allow_private_network_connections = false
tls_handshake_timeout_secs = 10
client_listener_timeout_secs = 600
connection_establishment_timeout_secs = 30
tcp_connections_timeout_secs = 604800
udp_connections_timeout_secs = 300
speedtest_enable = false

[listen_protocols]

[listen_protocols.http1]
upload_buffer_size = 32768

[listen_protocols.http2]
initial_connection_window_size = 8388608
initial_stream_window_size = 131072
max_concurrent_streams = 1000
max_frame_size = 16384
header_table_size = 65536

[listen_protocols.quic]
recv_udp_payload_size = 1350
send_udp_payload_size = 1350
initial_max_data = 104857600
initial_max_stream_data_bidi_local = 1048576
initial_max_stream_data_bidi_remote = 1048576
initial_max_stream_data_uni = 1048576
initial_max_streams_bidi = 4096
initial_max_streams_uni = 4096
max_connection_window = 25165824
max_stream_window = 16777216
disable_active_migration = true
enable_early_data = true
message_queue_capacity = 4096
EOF

    cat > hosts.toml << EOF
ping_hosts = []
speedtest_hosts = []
reverse_proxy_hosts = []

[[main_hosts]]
hostname = "$DOMAIN"
cert_chain_path = "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
private_key_path = "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
allowed_sni = ["time.android.com"]
EOF

    log_info "Конфигурация создана"

    popd > /dev/null
}

# ===========================
# 5. CHECK PORT AVAILABILITY
# ===========================
check_port_available() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || ss -ulnp 2>/dev/null | grep -q ":${port} "; then
        log_error "Порт ${port} уже занят. Освободите его или выберите другой."
        ss -tlnp 2>/dev/null | grep ":${port} " || true
        ss -ulnp 2>/dev/null | grep ":${port} " || true
        exit 1
    fi
}

# ===========================
# 6. GET LET'S ENCRYPT CERT
# ===========================
get_certificate() {
    log_info "Получаем Let's Encrypt сертификат для $DOMAIN..."

    if lsof -i :80 &>/dev/null || ss -tlnp | grep -q ':80 '; then
        log_warn "Порт 80 занят. Certbot может не сработать в standalone режиме."
        read -rp "Попробовать webroot режим? [y/N]: " use_webroot
        if [[ "$use_webroot" =~ ^[Yy]$ ]]; then
            read -rp "Путь к webroot [/var/www/html]: " WEBROOT
            WEBROOT=${WEBROOT:-/var/www/html}
            mkdir -p "$WEBROOT"
            certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" --agree-tos --non-interactive --email "admin@$DOMAIN" || {
                log_error "Не удалось получить сертификат через webroot"
                exit 1
            }
        else
            log_info "Пробуем standalone anyway..."
            certbot certonly --standalone -d "$DOMAIN" --agree-tos --non-interactive --email "admin@$DOMAIN" || {
                log_error "Не удалось получить сертификат. Убедитесь, что порт 80 свободен или настроен webroot"
                exit 1
            }
        fi
    else
        certbot certonly --standalone -d "$DOMAIN" --agree-tos --non-interactive --email "admin@$DOMAIN" || {
            log_error "Не удалось получить сертификат"
            exit 1
        }
    fi

    if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        log_error "Сертификат не найден после выпуска"
        exit 1
    fi

    log_info "Сертификат получен успешно"
}

# ===========================
# 7. SETUP AUTO-RENEWAL + HOOK
# ===========================
setup_auto_renewal() {
    log_info "Настраиваем автообновление сертификатов..."

    if systemctl list-timers 2>/dev/null | grep -qE 'certbot|letsencrypt'; then
        log_info "Certbot timer уже активен"
    else
        log_info "Включаем certbot timer..."
        systemctl enable certbot.timer 2>/dev/null || true
        systemctl start certbot.timer 2>/dev/null || true
    fi

    log_info "Добавляем deploy-hook для перезапуска TrustTunnel после обновления сертификата..."

    CERTBOT_VERSION=$(certbot --version 2>&1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
    CERTBOT_MAJOR=$(echo "$CERTBOT_VERSION" | cut -d. -f1)
    CERTBOT_MINOR=$(echo "$CERTBOT_VERSION" | cut -d. -f2)

    if [ "$CERTBOT_MAJOR" -gt 2 ] || ([ "$CERTBOT_MAJOR" -eq 2 ] && [ "$CERTBOT_MINOR" -ge 3 ]); then
        certbot reconfigure --deploy-hook "systemctl restart trusttunnel" -d "$DOMAIN" 2>/dev/null || {
            log_warn "Не удалось использовать reconfigure, пытаемся через renew-hook в конфиге..."
            setup_renew_hook_manual
        }
    else
        setup_renew_hook_manual
    fi

    if [ ! -f "/etc/cron.d/trusttunnel-cert-renewal" ]; then
        cat > /etc/cron.d/trusttunnel-cert-renewal << 'EOF'
0 3 * * * root certbot renew --quiet --deploy-hook "systemctl restart trusttunnel" >> /var/log/trusttunnel-cert-renewal.log 2>&1
EOF
        chmod 644 /etc/cron.d/trusttunnel-cert-renewal
        log_info "Cron fallback добавлен в /etc/cron.d/trusttunnel-cert-renewal"
    else
        log_info "Cron fallback уже существует, пропускаем"
    fi

    log_info "Тестируем обновление (dry-run)..."
    certbot renew --dry-run --quiet || log_warn "Dry-run не прошел, но это может быть нормально для свежего сертификата"
}

setup_renew_hook_manual() {
    local renewal_conf="/etc/letsencrypt/renewal/${DOMAIN}.conf"
    if [ -f "$renewal_conf" ]; then
        if ! grep -q "renew_hook = systemctl restart trusttunnel" "$renewal_conf"; then
            if grep -q "\[renewalparams\]" "$renewal_conf"; then
                sed -i '/\[renewalparams\]/a renew_hook = systemctl restart trusttunnel' "$renewal_conf"
            else
                printf '\n[renewalparams]\nrenew_hook = systemctl restart trusttunnel\n' >> "$renewal_conf"
            fi
            log_info "Renew hook добавлен в $renewal_conf"
        fi
    fi
}

# ===========================
# 8. SYSTEMD SERVICE
# ===========================
setup_systemd() {
    log_info "Настраиваем systemd сервис..."

    if [ -f "${TT_DIR}/trusttunnel.service.template" ]; then
        cp "${TT_DIR}/trusttunnel.service.template" /etc/systemd/system/trusttunnel.service
    else
        cat > /etc/systemd/system/trusttunnel.service << 'EOF'
[Unit]
Description=TrustTunnel VPN Endpoint
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/trusttunnel
ExecStart=/opt/trusttunnel/trusttunnel_endpoint vpn.toml hosts.toml
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    fi

    if ! grep -q "WorkingDirectory=/opt/trusttunnel" /etc/systemd/system/trusttunnel.service; then
        sed -i 's|WorkingDirectory=.*|WorkingDirectory=/opt/trusttunnel|' /etc/systemd/system/trusttunnel.service
    fi

    systemctl daemon-reload
    systemctl enable trusttunnel
    systemctl restart trusttunnel

    sleep 2
    if systemctl is-active --quiet trusttunnel; then
        log_info "TrustTunnel сервис запущен и активен"
    else
        log_error "TrustTunnel сервис не запустился. Смотрите: journalctl -u trusttunnel -n 50"
        exit 1
    fi
}

# ===========================
# 9. EXPORT CLIENT CONFIG (MULTI-USER)
# ===========================
export_client_config() {
    log_info "Генерируем клиентские конфигурации..."

    pushd "${TT_DIR}" > /dev/null

    SERVER_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')
    CLIENT_INFO_FILE="/root/trusttunnel_clients.txt"

    {
        echo "========================================"
        echo "  TRUSTTUNNEL CLIENT CONFIGURATION"
        echo "========================================"
        echo "Server:     $DOMAIN:$LISTEN_PORT"
        echo "IP:         $SERVER_IP"
        echo "Certificate: Let's Encrypt (auto-renewed)"
        echo ""
    } > "$CLIENT_INFO_FILE"

    for idx in "${!USERNAMES[@]}"; do
        local username="${USERNAMES[$idx]}"
        local password="${PASSWORDS[$idx]}"
        local client_name="${CLIENT_NAMES[$idx]}"
        local cred_file="/root/${client_name}_trusttunnel.toml"

        ./trusttunnel_endpoint vpn.toml hosts.toml -c "$username" -a "$DOMAIN:$LISTEN_PORT" --format toml > "$cred_file" 2>/dev/null || {
            log_warn "Не удалось сгенерировать TOML конфигурацию через endpoint binary для $username"
            cat > "$cred_file" << EOF
endpoint = "https://$DOMAIN:$LISTEN_PORT"
username = "$username"
password = "$password"
EOF
        }
        chmod 600 "$cred_file"

        local deeplink=""
        deeplink=$(./trusttunnel_endpoint vpn.toml hosts.toml -c "$username" -a "$DOMAIN:$LISTEN_PORT" --format deeplink 2>/dev/null || echo "")

        {
            echo "--- Пользователь: $username ---"
            echo "Файл конфигурации: ${cred_file}"
            echo "Пароль: $password"
        } >> "$CLIENT_INFO_FILE"

        if [ -n "$deeplink" ]; then
            echo "Deep Link: $deeplink" >> "$CLIENT_INFO_FILE"
            if command -v qrencode &>/dev/null; then
                echo "QR-код:" >> "$CLIENT_INFO_FILE"
                qrencode -t ANSIUTF8 "$deeplink" >> "$CLIENT_INFO_FILE" 2>/dev/null || true
            fi
        fi
        echo "" >> "$CLIENT_INFO_FILE"
    done

    echo "========================================" >> "$CLIENT_INFO_FILE"
    chmod 600 "$CLIENT_INFO_FILE"

    log_info "Клиентская информация сохранена в ${CLIENT_INFO_FILE}"
    log_info "Пароли сохранены только в файлах с правами 600 (root:root)"

    popd > /dev/null
}

# ===========================
# 10. FIREWALL (optional)
# ===========================
setup_firewall() {
    log_info "Настраиваем firewall..."

    if command -v ufw &>/dev/null; then
        ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
        ufw allow 80/tcp comment 'Certbot/HTTP' 2>/dev/null || true
        ufw allow "$LISTEN_PORT/tcp" comment 'TrustTunnel' 2>/dev/null || true
        ufw allow "$LISTEN_PORT/udp" comment 'TrustTunnel QUIC' 2>/dev/null || true
        ufw --force enable 2>/dev/null || true
        log_info "UFW настроен"
    fi

    iptables -I INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport "$LISTEN_PORT" -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport "$LISTEN_PORT" -j ACCEPT 2>/dev/null || true

    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save 2>/dev/null || true
        log_info "iptables правила сохранены через netfilter-persistent"
    elif command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        log_info "iptables правила сохранены в /etc/iptables/rules.v4"
    fi
}

# ===========================
# 11. AUTO-UPDATE TRUSTTUNNEL
# ===========================
setup_auto_update() {
    log_info "Настраиваем автообновление TrustTunnel..."

    local update_script="${TT_DIR}/trusttunnel-auto-update.sh"

    cat > "$update_script" << 'SCRIPT_EOF'
#!/bin/bash
# TrustTunnel Auto-Update Script
set -euo pipefail

TT_DIR="/opt/trusttunnel"
BACKUP_DIR="/opt/trusttunnel/backups"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/TrustTunnel/TrustTunnel/refs/heads/master/scripts/install.sh"
INSTALL_SCRIPT_SHA256_URL="${INSTALL_SCRIPT_URL}.sha256"
UPDATE_CHECK_FILE="${TT_DIR}/.last_install_sha256"
LOG_FILE="/var/log/trusttunnel-update.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

exec 200>/var/lock/trusttunnel-update.lock
if ! flock -n 200; then
    log "Обновление уже выполняется, пропускаем."
    exit 0
fi

log "=== Проверка обновлений TrustTunnel ==="

# Скачиваем актуальный checksum
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

if ! curl -fsSL -o "${tmpdir}/install.sh.sha256" "$INSTALL_SCRIPT_SHA256_URL" 2>/dev/null; then
    log "Не удалось скачать checksum. Пропускаем проверку."
    exit 0
fi

new_sha=$(awk '{print $1}' "${tmpdir}/install.sh.sha256")
old_sha=""
if [ -f "$UPDATE_CHECK_FILE" ]; then
    old_sha=$(cat "$UPDATE_CHECK_FILE")
fi

if [ "$new_sha" = "$old_sha" ]; then
    log "TrustTunnel актуален (SHA256 совпадает)."
    exit 0
fi

log "Найдено обновление TrustTunnel!"
log "Старый SHA: ${old_sha:-<нет>}"
log "Новый SHA:  $new_sha"

# Бэкап перед обновлением
ts=$(date +%Y%m%d%H%M%S)
mkdir -p "$BACKUP_DIR"
if [ -f "${TT_DIR}/trusttunnel_endpoint" ]; then
    cp "${TT_DIR}/trusttunnel_endpoint" "${BACKUP_DIR}/trusttunnel_endpoint.${ts}"
    log "Бэкап бинарника сохранён"
fi

# Скачиваем инсталлятор
curl -fsSL -o "${tmpdir}/install.sh" "$INSTALL_SCRIPT_URL"
actual_sha=$(sha256sum "${tmpdir}/install.sh" | awk '{print $1}')

if [ "$new_sha" != "$actual_sha" ]; then
    log "ОШИБКА: SHA256 не совпадает после скачивания!"
    exit 1
fi

# Останавливаем сервис
log "Останавливаем TrustTunnel..."
systemctl stop trusttunnel || true

# Запускаем установку
log "Запускаем инсталлятор..."
sh "${tmpdir}/install.sh"

# Проверяем установку
if [ ! -f "${TT_DIR}/trusttunnel_endpoint" ]; then
    log "ОШИБКА: Бинарник не найден после обновления! Восстанавливаем бэкап..."
    if [ -f "${BACKUP_DIR}/trusttunnel_endpoint.${ts}" ]; then
        cp "${BACKUP_DIR}/trusttunnel_endpoint.${ts}" "${TT_DIR}/trusttunnel_endpoint"
        systemctl start trusttunnel || true
    fi
    exit 1
fi

# Сохраняем новый checksum
echo "$new_sha" > "$UPDATE_CHECK_FILE"

# Перезапускаем
log "Перезапускаем TrustTunnel..."
systemctl daemon-reload
systemctl restart trusttunnel

sleep 2
if systemctl is-active --quiet trusttunnel; then
    log "TrustTunnel успешно обновлён и запущен."
else
    log "ОШИБКА: Сервис не запустился после обновления!"
    log "Смотрите: journalctl -u trusttunnel -n 50"
    exit 1
fi
SCRIPT_EOF

    chmod +x "$update_script"
    log_info "Скрипт автообновления создан: $update_script"

    # Systemd таймер для автообновления (каждый день в 4:30)
    cat > /etc/systemd/system/trusttunnel-update.service << EOF
[Unit]
Description=TrustTunnel Auto-Update Check
After=network.target

[Service]
Type=oneshot
ExecStart=$update_script
StandardOutput=journal
StandardError=journal
EOF

    cat > /etc/systemd/system/trusttunnel-update.timer << 'EOF'
[Unit]
Description=Run TrustTunnel Auto-Update daily

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable trusttunnel-update.timer
    systemctl start trusttunnel-update.timer

    # Cron fallback
    if [ ! -f "/etc/cron.d/trusttunnel-auto-update" ]; then
        cat > /etc/cron.d/trusttunnel-auto-update << EOF
30 4 * * * root $update_script >> /var/log/trusttunnel-update.log 2>&1
EOF
        chmod 644 /etc/cron.d/trusttunnel-auto-update
        log_info "Cron fallback добавлен в /etc/cron.d/trusttunnel-auto-update"
    fi

    log_info "Автообновление TrustTunnel настроено (systemd timer + cron fallback)"
    log_info "Проверка статуса таймера: systemctl status trusttunnel-update.timer"
}

# ===========================
# MAIN
# ===========================
main() {
    check_root
    check_tty
    install_deps
    install_trusttunnel
    get_user_input

    check_port_available "$LISTEN_PORT"

    generate_configs
    get_certificate
    setup_auto_renewal
    setup_systemd
    setup_auto_update
    export_client_config
    setup_firewall

    echo ""
    echo "========================================"
    echo "  УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!"
    echo "========================================"
    echo ""
    echo "Домен:        $DOMAIN"
    echo "Порт:         $LISTEN_PORT"
    echo "Пользователей: ${#USERNAMES[@]}"
    for idx in "${!USERNAMES[@]}"; do
        echo "  - ${USERNAMES[$idx]} (конфиг: /root/${CLIENT_NAMES[$idx]}_trusttunnel.toml)"
    done
    echo ""
    echo "Сертификат:   Let's Encrypt (автообновление настроено)"
    echo "Автообновление TrustTunnel: systemd timer + cron"
    echo "Сервис:       systemctl status trusttunnel"
    echo "Логи:         journalctl -u trusttunnel -f"
    echo "Обновления:   journalctl -u trusttunnel-update -f"
    echo "Клиент инфо:  /root/trusttunnel_clients.txt"
    echo ""
    echo "Для подключения:"
    echo "  1. Скачайте .toml файлы с сервера (/root/*_trusttunnel.toml)"
    echo "  2. Используйте TrustTunnel CLI клиент или мобильное приложение"
    echo ""
}

main "$@"
