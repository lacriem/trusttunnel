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
verify_gpg_signature() {
    local tt_gpg_key="28645AC9776EC4C00BCE2AFC0FE641E7235E2EC6"
    local tt_gpg_keyserver="keys.openpgp.org"

    if ! command -v gpg &>/dev/null; then
        log_warn "GPG не установлен — пропускаем проверку подписи бинарника"
        log_warn "Установите gnupg: apt-get install -y gnupg"
        return
    fi

    log_info "Импортируем GPG-ключ AdGuard для верификации бинарника..."
    gpg --keyserver "$tt_gpg_keyserver" --recv-key "$tt_gpg_key" 2>/dev/null || {
        log_warn "Не удалось импортировать GPG-ключ AdGuard с $tt_gpg_keyserver"
        log_warn "Попробуйте вручную: gpg --keyserver '$tt_gpg_keyserver' --recv-key '$tt_gpg_key'"
        return
    }

    local verified=0
    local binary_path="${TT_DIR}/trusttunnel_endpoint"

    # Ищем .sig файлы — могут лежать рядом с бинарником или в подпапке
    for sig_candidate in \
        "${TT_DIR}/trusttunnel_endpoint.sig" \
        "${TT_DIR}/trusttunnel/trusttunnel_endpoint.sig" \
        "${TT_DIR}"/*.sig; do
        if [ -f "$sig_candidate" ]; then
            log_info "Найден .sig-файл: $sig_candidate"
            if gpg --verify "$sig_candidate" "$binary_path" 2>&1 | grep -q "Good signature"; then
                log_info "GPG-подпись бинарника ВАЛИДНА (AdGuard)"
                verified=1
                break
            else
                log_error "GPG-подпись НЕДЕЙСТВИТЕЛЬНА для $sig_candidate!"
                log_error "Бинарник мог быть подменён. НЕ ИСПОЛЬЗУЙТЕ его."
                log_error "Проверьте вручную: gpg --verify $sig_candidate $binary_path"
                verified=-1
            fi
        fi
    done

    if [ "$verified" -eq 0 ]; then
        log_warn ".sig-файл не найден — GPG-верификация пропущена"
        log_warn "Возможно, установлена версия <0.9.126 (без подписи) или .sig лежит в другом месте."
        log_warn "Документация: https://github.com/TrustTunnel/TrustTunnel/blob/master/VERIFY_RELEASES.md"
    fi
}

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

    # GPG-верификация бинарника (c v0.9.126 релизы подписаны AdGuard)
    verify_gpg_signature
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
# ВНИМАНИЕ: правила фильтрации оцениваются по порядку.
# Если ни одно правило не совпало — соединение РАЗРЕШАЕТСЯ (default-allow).
# Настоятельно рекомендуется добавить разрешающие правила для ваших клиентов
# и завершить файл catch-all deny:
#
#   [[rule]]
#   action = "deny"
#
# Документация: https://github.com/TrustTunnel/TrustTunnel/blob/master/CONFIGURATION.md#rules-reference
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
tcp_connections_timeout_secs = 7200
udp_connections_timeout_secs = 300
speedtest_enable = false

[listen_protocols]

[listen_protocols.http1]
upload_buffer_size = 65536

[listen_protocols.http2]
initial_connection_window_size = 8388608
initial_stream_window_size = 131072
max_concurrent_streams = 1000
max_frame_size = 65536
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
enable_early_data = false
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
# 12. FULL UNINSTALL
# ===========================
uninstall_trusttunnel() {
    echo ""
    echo "=========================================="
    echo "  ПОЛНОЕ УДАЛЕНИЕ TRUSTTUNNEL"
    echo "=========================================="
    echo ""

    read -rp "Вы уверены, что хотите ПОЛНОСТЬЮ удалить TrustTunnel? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Удаление отменено"
        return
    fi

    log_info "Останавливаем и удаляем systemd-сервисы..."
    systemctl stop trusttunnel 2>/dev/null || true
    systemctl stop trusttunnel-update.timer 2>/dev/null || true
    systemctl disable trusttunnel 2>/dev/null || true
    systemctl disable trusttunnel-update.timer 2>/dev/null || true
    systemctl disable trusttunnel-update.service 2>/dev/null || true
    rm -f /etc/systemd/system/trusttunnel.service
    rm -f /etc/systemd/system/trusttunnel-update.service
    rm -f /etc/systemd/system/trusttunnel-update.timer
    systemctl daemon-reload

    log_info "Удаляем cron-задания..."
    rm -f /etc/cron.d/trusttunnel-cert-renewal
    rm -f /etc/cron.d/trusttunnel-auto-update

    log_info "Удаляем lock-файлы..."
    rm -f /var/lock/trusttunnel-update.lock

    log_info "Удаляем логи..."
    rm -f /var/log/trusttunnel-update.log
    rm -f /var/log/trusttunnel-cert-renewal.log

    # Чистим journald от логов TrustTunnel (требует прав)
    if command -v journalctl &>/dev/null; then
        journalctl --vacuum-time=1s --unit=trusttunnel 2>/dev/null || true
        journalctl --vacuum-time=1s --unit=trusttunnel-update 2>/dev/null || true
    fi

    log_info "Удаляем рабочую директорию /opt/trusttunnel..."
    rm -rf /opt/trusttunnel

    log_info "Удаляем клиентские конфигурации из /root/..."
    rm -f /root/trusttunnel_clients.txt
    rm -f /root/*_trusttunnel.toml

    # Сертификаты Let's Encrypt
    if [ -d /etc/letsencrypt/live ] && [ -n "$(ls -A /etc/letsencrypt/live 2>/dev/null)" ]; then
        echo ""
        read -rp "Удалить сертификаты Let's Encrypt? [y/N]: " del_certs
        if [[ "$del_certs" =~ ^[Yy]$ ]]; then
            log_info "Удаляем сертификаты Let's Encrypt..."
            certbot delete --non-interactive 2>/dev/null || {
                # Ручное удаление если certbot delete не сработал
                rm -rf /etc/letsencrypt/live/*
                rm -rf /etc/letsencrypt/archive/*
                rm -rf /etc/letsencrypt/renewal/*
            }
        fi
    fi

    # Правила файрвола
    echo ""
    read -rp "Удалить правила файрвола TrustTunnel? [y/N]: " del_fw
    if [[ "$del_fw" =~ ^[Yy]$ ]]; then
        if command -v ufw &>/dev/null && ufw status | grep -q 'TrustTunnel'; then
            log_info "Удаляем правила UFW для TrustTunnel..."
            # Удаляем по номерам правил с конца
            ufw status numbered | grep -i 'TrustTunnel\|trusttunnel' | awk -F'[][]' '{print $2}' | sort -rn | while read -r num; do
                ufw --force delete "$num" 2>/dev/null || true
            done
        fi
        log_info "Очистка iptables (только правила TrustTunnel не трогаем,"
        log_info "  полный сброс делается вручную: iptables -F && netfilter-persistent save)"
        rm -f /etc/iptables/rules.v4
    fi

    # Чистим кэш apt
    log_info "Очищаем кэш apt..."
    apt-get clean -qq 2>/dev/null || true
    apt-get autoclean -qq 2>/dev/null || true

    # Удаляем GPG-ключ AdGuard из связки root
    if command -v gpg &>/dev/null; then
        gpg --batch --yes --delete-key "28645AC9776EC4C00BCE2AFC0FE641E7235E2EC6" 2>/dev/null || true
    fi

    echo ""
    log_info "========================================"
    log_info "  TRUSTTUNNEL ПОЛНОСТЬЮ УДАЛЁН"
    log_info "========================================"
    echo ""
    echo "Удалено:"
    echo "  - systemd-сервисы и таймеры"
    echo "  - cron-задания"
    echo "  - /opt/trusttunnel/ (бинарник, конфиги, бэкапы, автообновление)"
    echo "  - /root/*_trusttunnel.toml (клиентские конфиги)"
    echo "  - Логи (/var/log/trusttunnel-*)"
    echo "  - Кэш apt"
    echo ""
}

# ===========================
# 13. MENU SYSTEM
# ===========================

BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'

show_header() {
    clear 2>/dev/null || true
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        TRUSTTUNNEL VPN MANAGER v2            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

press_enter() {
    echo ""
    read -rp "Нажмите Enter для продолжения..." _
}

full_install() {
    show_header
    echo "=== ПОЛНАЯ УСТАНОВКА TRUSTTUNNEL ==="
    echo ""
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
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}    УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "Домен:        ${BOLD}$DOMAIN${NC}"
    echo -e "Порт:         ${BOLD}$LISTEN_PORT${NC}"
    echo -e "Пользователей: ${BOLD}${#USERNAMES[@]}${NC}"
    for idx in "${!USERNAMES[@]}"; do
        echo "  - ${USERNAMES[$idx]} (конфиг: /root/${CLIENT_NAMES[$idx]}_trusttunnel.toml)"
    done
    echo ""
    echo "Сертификат:   Let's Encrypt (автообновление)"
    echo "Сервис:       systemctl status trusttunnel"
    echo "Логи:         journalctl -u trusttunnel -f"
    echo "Клиент инфо:  /root/trusttunnel_clients.txt"
    echo ""
    press_enter
}

# -------- PRESETS --------

apply_preset() {
    local config="${TT_DIR}/vpn.toml"
    if [ ! -f "$config" ]; then
        log_error "vpn.toml не найден. Сначала установите TrustTunnel."
        press_enter
        return
    fi

    show_header
    echo "=== ПРЕСЕТЫ КОНФИГУРАЦИИ ==="
    echo ""
    echo "  ${BOLD}1) mobile${NC}      — низкие таймауты, оптимизация для 4G/5G"
    echo "  ${BOLD}2) performance${NC} — большие буферы, для гигабитных каналов"
    echo "  ${BOLD}3) stealth${NC}     — консервативные настройки, обход DPI"
    echo "  ${BOLD}4) balanced${NC}    — сбалансированные значения (рекомендуется)"
    echo ""
    read -rp "Выберите пресет [1-4]: " preset

    local ts=$(date +%Y%m%d%H%M%S)
    cp "$config" "${BACKUP_DIR}/vpn.toml.before_preset.${ts}" 2>/dev/null || true

    case "$preset" in
        1)
            log_info "Применяем пресет: mobile"
            sed -i 's/^tcp_connections_timeout_secs = .*/tcp_connections_timeout_secs = 3600/' "$config"
            sed -i 's/^udp_connections_timeout_secs = .*/udp_connections_timeout_secs = 180/' "$config"
            sed -i 's/^client_listener_timeout_secs = .*/client_listener_timeout_secs = 300/' "$config"
            sed -i 's/^max_concurrent_streams = .*/max_concurrent_streams = 256/' "$config"
            sed -i 's/^initial_max_data = .*/initial_max_data = 52428800/' "$config"
            sed -i 's/^message_queue_capacity = .*/message_queue_capacity = 2048/' "$config"
            ;;
        2)
            log_info "Применяем пресет: performance"
            sed -i 's/^max_concurrent_streams = .*/max_concurrent_streams = 2000/' "$config"
            sed -i 's/^initial_connection_window_size = .*/initial_connection_window_size = 16777216/' "$config"
            sed -i 's/^initial_stream_window_size = .*/initial_stream_window_size = 524288/' "$config"
            sed -i 's/^upload_buffer_size = .*/upload_buffer_size = 131072/' "$config"
            sed -i 's/^initial_max_streams_bidi = .*/initial_max_streams_bidi = 8192/' "$config"
            sed -i 's/^initial_max_streams_uni = .*/initial_max_streams_uni = 8192/' "$config"
            sed -i 's/^message_queue_capacity = .*/message_queue_capacity = 8192/' "$config"
            ;;
        3)
            log_info "Применяем пресет: stealth"
            sed -i 's/^max_frame_size = .*/max_frame_size = 16384/' "$config"
            sed -i 's/^max_concurrent_streams = .*/max_concurrent_streams = 100/' "$config"
            sed -i 's/^initial_max_streams_bidi = .*/initial_max_streams_bidi = 128/' "$config"
            sed -i 's/^initial_max_streams_uni = .*/initial_max_streams_uni = 128/' "$config"
            sed -i 's/^enable_early_data = .*/enable_early_data = false/' "$config"
            sed -i 's/^send_udp_payload_size = .*/send_udp_payload_size = 1200/' "$config"
            sed -i 's/^recv_udp_payload_size = .*/recv_udp_payload_size = 1200/' "$config"
            ;;
        4)
            log_info "Применяем пресет: balanced (значения по умолчанию)"
            sed -i 's/^tcp_connections_timeout_secs = .*/tcp_connections_timeout_secs = 7200/' "$config"
            sed -i 's/^udp_connections_timeout_secs = .*/udp_connections_timeout_secs = 300/' "$config"
            sed -i 's/^client_listener_timeout_secs = .*/client_listener_timeout_secs = 600/' "$config"
            sed -i 's/^max_concurrent_streams = .*/max_concurrent_streams = 1000/' "$config"
            sed -i 's/^initial_connection_window_size = .*/initial_connection_window_size = 8388608/' "$config"
            sed -i 's/^initial_stream_window_size = .*/initial_stream_window_size = 131072/' "$config"
            sed -i 's/^upload_buffer_size = .*/upload_buffer_size = 65536/' "$config"
            sed -i 's/^max_frame_size = .*/max_frame_size = 65536/' "$config"
            sed -i 's/^initial_max_data = .*/initial_max_data = 104857600/' "$config"
            sed -i 's/^initial_max_streams_bidi = .*/initial_max_streams_bidi = 4096/' "$config"
            sed -i 's/^initial_max_streams_uni = .*/initial_max_streams_uni = 4096/' "$config"
            sed -i 's/^message_queue_capacity = .*/message_queue_capacity = 4096/' "$config"
            sed -i 's/^enable_early_data = .*/enable_early_data = false/' "$config"
            sed -i 's/^send_udp_payload_size = .*/send_udp_payload_size = 1350/' "$config"
            sed -i 's/^recv_udp_payload_size = .*/recv_udp_payload_size = 1350/' "$config"
            ;;
        *)
            log_error "Неверный выбор"
            press_enter
            return
            ;;
    esac

    log_info "Бэкап сохранён: ${BACKUP_DIR}/vpn.toml.before_preset.${ts}"

    if systemctl is-active --quiet trusttunnel 2>/dev/null; then
        read -rp "Перезапустить TrustTunnel для применения? [Y/n]: " restart
        if [[ ! "$restart" =~ ^[Nn]$ ]]; then
            systemctl restart trusttunnel
            log_info "Сервис перезапущен"
        fi
    fi
    press_enter
}

# -------- RECONFIGURE --------

reconfigure_menu() {
    while true; do
        show_header
        echo "=== НАСТРОЙКА КОНФИГУРАЦИИ ==="
        echo ""
        echo "  1) Применить пресет (mobile / performance / stealth / balanced)"
        echo "  2) Редактировать rules.toml (фильтрация подключений)"
        echo "  3) Редактировать vpn.toml вручную"
        echo "  4) Перезагрузить TLS-хосты (SIGHUP)"
        echo "  5) Просмотр текущей конфигурации"
        echo ""
        echo "  0) Назад"
        echo ""
        read -rp "Выберите пункт [0-5]: " choice

        case "$choice" in
            1) apply_preset ;;
            2)
                if [ -f "${TT_DIR}/rules.toml" ]; then
                    nano "${TT_DIR}/rules.toml"
                    if systemctl is-active --quiet trusttunnel 2>/dev/null; then
                        read -rp "Перезапустить TrustTunnel? [y/N]: " restart
                        [[ "$restart" =~ ^[Yy]$ ]] && systemctl restart trusttunnel
                    fi
                else
                    log_error "rules.toml не найден. Сначала установите TrustTunnel."
                    press_enter
                fi
                ;;
            3)
                if [ -f "${TT_DIR}/vpn.toml" ]; then
                    cp "${TT_DIR}/vpn.toml" "${BACKUP_DIR}/vpn.toml.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
                    nano "${TT_DIR}/vpn.toml"
                    if systemctl is-active --quiet trusttunnel 2>/dev/null; then
                        read -rp "Перезапустить TrustTunnel? [y/N]: " restart
                        [[ "$restart" =~ ^[Yy]$ ]] && systemctl restart trusttunnel
                    fi
                else
                    log_error "vpn.toml не найден. Сначала установите TrustTunnel."
                    press_enter
                fi
                ;;
            4)
                if systemctl is-active --quiet trusttunnel 2>/dev/null; then
                    systemctl reload trusttunnel 2>/dev/null || kill -HUP "$(pidof trusttunnel_endpoint 2>/dev/null || echo 0)" 2>/dev/null || log_warn "Не удалось отправить SIGHUP"
                    log_info "TLS-хосты перезагружены"
                else
                    log_error "TrustTunnel не запущен"
                fi
                press_enter
                ;;
            5)
                show_header
                echo "=== ТЕКУЩАЯ КОНФИГУРАЦИЯ ==="
                echo ""
                if [ -f "${TT_DIR}/vpn.toml" ]; then
                    echo -e "${CYAN}--- vpn.toml ---${NC}"
                    cat "${TT_DIR}/vpn.toml"
                fi
                if [ -f "${TT_DIR}/hosts.toml" ]; then
                    echo ""
                    echo -e "${CYAN}--- hosts.toml ---${NC}"
                    cat "${TT_DIR}/hosts.toml"
                fi
                if [ -f "${TT_DIR}/rules.toml" ] && [ -s "${TT_DIR}/rules.toml" ]; then
                    echo ""
                    echo -e "${CYAN}--- rules.toml ---${NC}"
                    cat "${TT_DIR}/rules.toml"
                fi
                press_enter
                ;;
            0) return ;;
            *) log_warn "Неверный выбор" && sleep 1 ;;
        esac
    done
}

# -------- USER MANAGEMENT --------

list_users() {
    local cred_file="${TT_DIR}/credentials.toml"
    if [ ! -f "$cred_file" ]; then
        echo "  (нет пользователей — credentials.toml не найден)"
        return
    fi
    local count=0
    while IFS= read -r line; do
        if [[ "$line" =~ username[[:space:]]*=[[:space:]]*\"(.+)\" ]]; then
            count=$((count + 1))
            echo "  $count) ${BASH_REMATCH[1]}"
        fi
    done < "$cred_file"
    if [ "$count" -eq 0 ]; then
        echo "  (нет пользователей)"
    fi
}

add_user() {
    local cred_file="${TT_DIR}/credentials.toml"
    if [ ! -f "$cred_file" ]; then
        log_error "credentials.toml не найден. Сначала установите TrustTunnel."
        press_enter
        return
    fi

    show_header
    echo "=== ДОБАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯ ==="
    echo ""
    echo "Текущие пользователи:"
    list_users
    echo ""

    local username password client_name
    while true; do
        read -rp "Имя пользователя: " username
        [[ "$username" =~ ^[a-zA-Z0-9_-]+$ ]] && break
        log_error "Только буквы, цифры, _ и -"
    done

    if grep -q "username = \"$username\"" "$cred_file"; then
        log_error "Пользователь $username уже существует"
        press_enter
        return
    fi

    read -rsp "Пароль (Enter = сгенерировать): " password
    echo ""
    if [ -z "$password" ]; then
        password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        log_info "Сгенерирован пароль: $password"
    fi

    echo "" >> "$cred_file"
    cat >> "$cred_file" << EOF
[[client]]
username = "$username"
password = "$password"
EOF
    chmod 600 "$cred_file"
    log_info "Пользователь $username добавлен"

    # Экспорт клиентской конфигурации
    if [ -f "${TT_DIR}/trusttunnel_endpoint" ]; then
        read -rp "Имя файла конфигурации [$username]: " client_name
        client_name=${client_name:-$username}
        local cred_file_client="/root/${client_name}_trusttunnel.toml"
        local domain port
        domain=$(grep -oP 'hostname\s*=\s*"\K[^"]+' "${TT_DIR}/hosts.toml" 2>/dev/null | head -1 || echo "unknown")
        port=$(grep -oP 'listen_address\s*=\s*"[^:]+:\K[0-9]+' "${TT_DIR}/vpn.toml" 2>/dev/null || echo "443")

        pushd "${TT_DIR}" > /dev/null
        ./trusttunnel_endpoint vpn.toml hosts.toml -c "$username" -a "$domain:$port" --format toml > "$cred_file_client" 2>/dev/null || {
            cat > "$cred_file_client" << EOF2
endpoint = "https://$domain:$port"
username = "$username"
password = "$password"
EOF2
        }
        chmod 600 "$cred_file_client"
        popd > /dev/null

        # QR-код
        local deeplink
        deeplink=$(pushd "${TT_DIR}" > /dev/null && ./trusttunnel_endpoint vpn.toml hosts.toml -c "$username" -a "$domain:$port" --format deeplink 2>/dev/null; popd > /dev/null)
        if [ -n "$deeplink" ] && command -v qrencode &>/dev/null; then
            echo "QR-код для $username:"
            qrencode -t ANSIUTF8 "$deeplink" 2>/dev/null || true
        fi
        log_info "Клиентская конфигурация: $cred_file_client"
    fi

    # Перезапуск сервиса для применения
    if systemctl is-active --quiet trusttunnel 2>/dev/null; then
        read -rp "Перезапустить TrustTunnel для применения? [Y/n]: " restart
        [[ ! "$restart" =~ ^[Nn]$ ]] && systemctl restart trusttunnel
    fi
    press_enter
}

remove_user() {
    local cred_file="${TT_DIR}/credentials.toml"
    if [ ! -f "$cred_file" ]; then
        log_error "credentials.toml не найден"
        press_enter
        return
    fi

    show_header
    echo "=== УДАЛЕНИЕ ПОЛЬЗОВАТЕЛЯ ==="
    echo ""
    echo "Текущие пользователи:"
    list_users
    echo ""

    read -rp "Имя пользователя для удаления: " username
    if ! grep -q "username = \"$username\"" "$cred_file"; then
        log_error "Пользователь $username не найден"
        press_enter
        return
    fi

    read -rp "Удалить пользователя $username? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        cp "$cred_file" "${BACKUP_DIR}/credentials.toml.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        # Удаляем блок [[client]] ... с этим username
        sed -i "/^\[\[client\]\]$/,/^$/{/username = \"$username\"/d}" "$cred_file" 2>/dev/null || true
        # Удаляем пустые блоки и строки
        sed -i '/^\[\[client\]\]$/{ N; /^\[\[client\]\]\n$/d; }' "$cred_file" 2>/dev/null || true
        log_info "Пользователь $username удалён"
        if systemctl is-active --quiet trusttunnel 2>/dev/null; then
            read -rp "Перезапустить TrustTunnel? [Y/n]: " restart
            [[ ! "$restart" =~ ^[Nn]$ ]] && systemctl restart trusttunnel
        fi
    fi
    press_enter
}

change_user_password() {
    local cred_file="${TT_DIR}/credentials.toml"
    if [ ! -f "$cred_file" ]; then
        log_error "credentials.toml не найден"
        press_enter
        return
    fi

    show_header
    echo "=== СМЕНА ПАРОЛЯ ==="
    echo ""
    echo "Текущие пользователи:"
    list_users
    echo ""

    read -rp "Имя пользователя: " username
    if ! grep -q "username = \"$username\"" "$cred_file"; then
        log_error "Пользователь $username не найден"
        press_enter
        return
    fi

    read -rsp "Новый пароль (Enter = сгенерировать): " newpass
    echo ""
    if [ -z "$newpass" ]; then
        newpass=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        log_info "Сгенерирован пароль: $newpass"
    fi

    cp "$cred_file" "${BACKUP_DIR}/credentials.toml.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    sed -i "/username = \"$username\"/{n;s/password = \".*\"/password = \"$newpass\"/;}" "$cred_file"
    log_info "Пароль для $username изменён"

    # Обновить клиентский конфиг
    local client_file
    client_file=$(find /root -maxdepth 1 -name "*_trusttunnel.toml" -exec grep -l "username = \"$username\"" {} \; 2>/dev/null | head -1)
    if [ -n "$client_file" ]; then
        sed -i "s/password = \".*\"/password = \"$newpass\"/" "$client_file"
        log_info "Клиентский конфиг $client_file обновлён"
    fi

    press_enter
}

export_client_for_user() {
    local cred_file="${TT_DIR}/credentials.toml"
    if [ ! -f "$cred_file" ] || [ ! -f "${TT_DIR}/trusttunnel_endpoint" ]; then
        log_error "TrustTunnel не установлен полностью"
        press_enter
        return
    fi

    show_header
    echo "=== ЭКСПОРТ КЛИЕНТСКОЙ КОНФИГУРАЦИИ ==="
    echo ""
    echo "Текущие пользователи:"
    list_users
    echo ""

    read -rp "Имя пользователя: " username
    if ! grep -q "username = \"$username\"" "$cred_file"; then
        log_error "Пользователь $username не найден"
        press_enter
        return
    fi

    local domain port
    domain=$(grep -oP 'hostname\s*=\s*"\K[^"]+' "${TT_DIR}/hosts.toml" 2>/dev/null | head -1 || echo "unknown")
    port=$(grep -oP 'listen_address\s*=\s*"[^:]+:\K[0-9]+' "${TT_DIR}/vpn.toml" 2>/dev/null || echo "443")

    local outfile="/root/${username}_trusttunnel.toml"
    pushd "${TT_DIR}" > /dev/null
    ./trusttunnel_endpoint vpn.toml hosts.toml -c "$username" -a "$domain:$port" --format toml > "$outfile" 2>/dev/null || {
        local password
        password=$(grep -A1 "username = \"$username\"" "$cred_file" | grep -oP 'password\s*=\s*"\K[^"]+')
        cat > "$outfile" << EOF2
endpoint = "https://$domain:$port"
username = "$username"
password = "$password"
EOF2
    }
    chmod 600 "$outfile"
    popd > /dev/null

    log_info "Конфигурация сохранена: $outfile"

    local deeplink
    deeplink=$(pushd "${TT_DIR}" > /dev/null && ./trusttunnel_endpoint vpn.toml hosts.toml -c "$username" -a "$domain:$port" --format deeplink 2>/dev/null; popd > /dev/null)
    if [ -n "$deeplink" ]; then
        echo "Deep Link: $deeplink"
        if command -v qrencode &>/dev/null; then
            qrencode -t ANSIUTF8 "$deeplink" 2>/dev/null || true
        fi
    fi
    press_enter
}

user_management_menu() {
    while true; do
        show_header
        echo "=== УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ ==="
        echo ""
        if [ -f "${TT_DIR}/credentials.toml" ]; then
            list_users
        else
            echo "  (credentials.toml не найден — TrustTunnel не установлен)"
        fi
        echo ""
        echo "  1) Добавить пользователя"
        echo "  2) Удалить пользователя"
        echo "  3) Сменить пароль"
        echo "  4) Экспортировать клиентскую конфигурацию"
        echo ""
        echo "  0) Назад"
        echo ""
        read -rp "Выберите пункт [0-4]: " choice

        case "$choice" in
            1) add_user ;;
            2) remove_user ;;
            3) change_user_password ;;
            4) export_client_for_user ;;
            0) return ;;
            *) log_warn "Неверный выбор" && sleep 1 ;;
        esac
    done
}

# -------- CERTIFICATES --------

certificate_menu() {
    while true; do
        show_header
        echo "=== СЕРТИФИКАТЫ LET'S ENCRYPT ==="
        echo ""

        # Показываем домены из hosts.toml
        if [ -f "${TT_DIR}/hosts.toml" ]; then
            local domains
            domains=$(grep -oP 'hostname\s*=\s*"\K[^"]+' "${TT_DIR}/hosts.toml" 2>/dev/null || echo "")
            if [ -n "$domains" ]; then
                echo "Домены в конфигурации:"
                echo "$domains" | while read -r d; do echo "  - $d"; done
                echo ""
            fi
        fi

        # Статус сертификатов
        if command -v certbot &>/dev/null; then
            echo "Сертификаты certbot:"
            certbot certificates 2>/dev/null | grep -E 'Domains:|Expiry Date:|VALID' || echo "  (нет сертификатов)"
        fi
        echo ""
        echo "  1) Проверить срок действия сертификатов"
        echo "  2) Принудительно обновить сертификаты"
        echo "  3) Информация о сертификате (openssl)"
        echo "  4) Dry-run проверка автообновления"
        echo ""
        echo "  0) Назад"
        echo ""
        read -rp "Выберите пункт [0-4]: " choice

        case "$choice" in
            1)
                if command -v certbot &>/dev/null; then
                    certbot certificates 2>/dev/null || log_warn "Нет сертификатов или certbot не настроен"
                else
                    log_error "certbot не установлен"
                fi
                press_enter
                ;;
            2)
                log_info "Принудительное обновление сертификатов..."
                certbot renew --force-renewal 2>&1 || log_error "Ошибка обновления"
                if systemctl is-active --quiet trusttunnel 2>/dev/null; then
                    systemctl restart trusttunnel
                    log_info "TrustTunnel перезапущен с новыми сертификатами"
                fi
                press_enter
                ;;
            3)
                read -rp "Домен (Enter = автоопределение): " domain
                if [ -z "$domain" ]; then
                    domain=$(grep -oP 'hostname\s*=\s*"\K[^"]+' "${TT_DIR}/hosts.toml" 2>/dev/null | head -1 || echo "")
                fi
                local cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
                if [ -f "$cert_path" ]; then
                    openssl x509 -in "$cert_path" -text -noout | grep -E 'Subject:|Issuer:|Not Before|Not After|DNS:' || true
                else
                    log_error "Сертификат для $domain не найден"
                fi
                press_enter
                ;;
            4)
                log_info "Тестирование автообновления (dry-run)..."
                certbot renew --dry-run 2>&1 || log_warn "Dry-run завершился с ошибкой (может быть нормально для свежих сертификатов)"
                press_enter
                ;;
            0) return ;;
            *) log_warn "Неверный выбор" && sleep 1 ;;
        esac
    done
}

# -------- SERVICE CONTROL --------

service_menu() {
    while true; do
        show_header
        echo "=== УПРАВЛЕНИЕ СЕРВИСОМ ==="
        echo ""

        local svc_active="остановлен"
        local svc_color="$RED"
        if systemctl is-active --quiet trusttunnel 2>/dev/null; then
            svc_active="активен"
            svc_color="$GREEN"
        fi
        echo -e "Статус: ${svc_color}${svc_active}${NC}"
        echo ""

        echo "  1) Запустить"
        echo "  2) Остановить"
        echo "  3) Перезапустить"
        echo "  4) Статус (подробно)"
        echo "  5) Логи (последние 50 строк)"
        echo "  6) Логи в реальном времени (Ctrl+C для выхода)"
        echo "  7) Проверить порты"
        echo ""
        echo "  0) Назад"
        echo ""
        read -rp "Выберите пункт [0-7]: " choice

        case "$choice" in
            1)
                systemctl start trusttunnel 2>/dev/null && log_info "Сервис запущен" || log_error "Ошибка запуска"
                press_enter
                ;;
            2)
                systemctl stop trusttunnel 2>/dev/null && log_info "Сервис остановлен" || log_error "Ошибка остановки"
                press_enter
                ;;
            3)
                systemctl restart trusttunnel 2>/dev/null && log_info "Сервис перезапущен" || log_error "Ошибка перезапуска"
                press_enter
                ;;
            4)
                systemctl status trusttunnel 2>/dev/null || log_error "Сервис не найден"
                press_enter
                ;;
            5)
                journalctl -u trusttunnel -n 50 --no-pager 2>/dev/null || log_error "Логи не найдены"
                press_enter
                ;;
            6)
                log_info "Логи в реальном времени (Ctrl+C для выхода)..."
                journalctl -u trusttunnel -f 2>/dev/null || log_error "Логи не найдены"
                ;;
            7)
                echo ""
                echo "Открытые порты TrustTunnel:"
                local port
                port=$(grep -oP 'listen_address\s*=\s*"[^:]+:\K[0-9]+' "${TT_DIR}/vpn.toml" 2>/dev/null || echo "")
                if [ -n "$port" ]; then
                    ss -tlnp 2>/dev/null | grep ":$port " || echo "  (порт $port не слушается)"
                    echo ""
                    ss -ulnp 2>/dev/null | grep ":$port " || echo "  (UDP порт $port не слушается)"
                else
                    log_warn "Не удалось определить порт из конфигурации"
                fi
                press_enter
                ;;
            0) return ;;
            *) log_warn "Неверный выбор" && sleep 1 ;;
        esac
    done
}

# -------- STATUS --------

show_status() {
    show_header
    echo "=== СТАТУС СИСТЕМЫ ==="
    echo ""

    # Сервис
    echo -n "Сервис:     "
    if systemctl is-active --quiet trusttunnel 2>/dev/null; then
        echo -e "${GREEN}активен${NC}"
        local uptime_str
        uptime_str=$(systemctl show trusttunnel -p ActiveEnterTimestamp 2>/dev/null | cut -d= -f2 || echo "неизвестно")
        echo "  Запущен:  $uptime_str"
    else
        echo -e "${RED}остановлен${NC}"
    fi

    # Конфигурация
    if [ -f "${TT_DIR}/vpn.toml" ]; then
        local port domain
        port=$(grep -oP 'listen_address\s*=\s*"[^:]+:\K[0-9]+' "${TT_DIR}/vpn.toml" 2>/dev/null || echo "?")
        echo "Порт:       $port"
    fi
    if [ -f "${TT_DIR}/hosts.toml" ]; then
        local domain
        domain=$(grep -oP 'hostname\s*=\s*"\K[^"]+' "${TT_DIR}/hosts.toml" 2>/dev/null | head -1 || echo "?")
        echo "Домен:      $domain"
    fi

    # Пользователи
    if [ -f "${TT_DIR}/credentials.toml" ]; then
        local user_count
        user_count=$(grep -c 'username' "${TT_DIR}/credentials.toml" 2>/dev/null || echo "0")
        echo "Клиентов:   $user_count"
    fi

    # Сертификат
    if [ -f "${TT_DIR}/hosts.toml" ]; then
        local domain cert_path
        domain=$(grep -oP 'hostname\s*=\s*"\K[^"]+' "${TT_DIR}/hosts.toml" 2>/dev/null | head -1 || echo "")
        cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
        if [ -f "$cert_path" ]; then
            local expiry
            expiry=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2 || echo "?")
            echo "Сертификат: до $expiry"
        else
            echo "Сертификат: ${RED}не найден${NC}"
        fi
    fi

    # Диск
    if [ -d "$TT_DIR" ]; then
        local disk_usage
        disk_usage=$(du -sh "$TT_DIR" 2>/dev/null | cut -f1 || echo "?")
        echo "Диск:       $disk_usage (/opt/trusttunnel)"
    fi

    # Версия бинарника
    if [ -f "${TT_DIR}/trusttunnel_endpoint" ]; then
        local version
        version=$("${TT_DIR}/trusttunnel_endpoint" --version 2>/dev/null | head -1 || echo "неизвестна")
        echo "Версия:     $version"
    fi

    # Память
    if pidof trusttunnel_endpoint &>/dev/null; then
        local pid mem
        pid=$(pidof trusttunnel_endpoint 2>/dev/null || echo "")
        if [ -n "$pid" ]; then
            mem=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.1f MB", $1/1024}' || echo "?")
            echo "PID:        $pid"
            echo "Память:     $mem"
        fi
    fi

    # Автообновление
    echo ""
    echo "Автообновление:"
    if systemctl is-active --quiet trusttunnel-update.timer 2>/dev/null; then
        echo -e "  Таймер: ${GREEN}активен${NC}"
    else
        echo -e "  Таймер: остановлен"
    fi
    if [ -f /etc/cron.d/trusttunnel-auto-update ]; then
        echo "  Cron:    настроен"
    fi

    echo ""
    press_enter
}

# -------- UPDATE --------

update_trusttunnel() {
    show_header
    echo "=== ОБНОВЛЕНИЕ TRUSTTUNNEL ==="
    echo ""

    if [ ! -f "${TT_DIR}/trusttunnel_endpoint" ]; then
        log_error "TrustTunnel не установлен. Выполните полную установку."
        press_enter
        return
    fi

    local current_ver
    current_ver=$("${TT_DIR}/trusttunnel_endpoint" --version 2>/dev/null | head -1 || echo "неизвестна")
    echo "Текущая версия: $current_ver"
    echo ""

    read -rp "Проверить и установить обновление? [y/N]: " do_update
    if [[ ! "$do_update" =~ ^[Yy]$ ]]; then
        return
    fi

    if [ -f "${TT_DIR}/trusttunnel-auto-update.sh" ]; then
        log_info "Запускаем скрипт автообновления..."
        bash "${TT_DIR}/trusttunnel-auto-update.sh"
    else
        log_info "Скрипт автообновления не найден, выполняем ручное обновление..."
        systemctl stop trusttunnel 2>/dev/null || true
        rm -rf "${TT_DIR}/trusttunnel_endpoint" 2>/dev/null || true
        install_trusttunnel
        if systemctl is-enabled trusttunnel &>/dev/null; then
            systemctl restart trusttunnel
        fi
    fi
    press_enter
}

# -------- MAIN MENU --------

show_main_menu() {
    while true; do
        show_header

        # Компактный статус
        if systemctl is-active --quiet trusttunnel 2>/dev/null; then
            echo -e "  Сервис: ${GREEN}● активен${NC}"
        else
            echo -e "  Сервис: ${RED}● остановлен${NC}"
        fi
        if [ -f "${TT_DIR}/credentials.toml" ]; then
            local uc
            uc=$(grep -c 'username' "${TT_DIR}/credentials.toml" 2>/dev/null || echo "0")
            echo "  Клиентов: $uc"
        fi
        echo ""

        echo "  ${BOLD}1)${NC} Установить / переустановить TrustTunnel"
        echo "  ${BOLD}2)${NC} Настройка (пресеты / правила / конфигурация)"
        echo "  ${BOLD}3)${NC} Пользователи (добавить / удалить / пароль / экспорт)"
        echo "  ${BOLD}4)${NC} Сертификаты (статус / продление / информация)"
        echo "  ${BOLD}5)${NC} Сервис (запуск / остановка / логи / порты)"
        echo "  ${BOLD}6)${NC} Обновить TrustTunnel"
        echo "  ${BOLD}7)${NC} Статус системы"
        echo ""
        echo "  ${RED}8)${NC} Полное удаление TrustTunnel"
        echo "  ${BOLD}0)${NC} Выход"
        echo ""
        read -rp "Выберите пункт [0-8]: " choice

        case "$choice" in
            1) full_install ;;
            2) reconfigure_menu ;;
            3) user_management_menu ;;
            4) certificate_menu ;;
            5) service_menu ;;
            6) update_trusttunnel ;;
            7) show_status ;;
            8) uninstall_trusttunnel ;;
            0) echo ""; echo "До свидания!"; exit 0 ;;
            *) log_warn "Неверный выбор" && sleep 1 ;;
        esac
    done
}

# ===========================
# MAIN
# ===========================
main() {
    # Обработка аргументов командной строки
    if [ "${1:-}" = "--uninstall" ]; then
        check_root
        uninstall_trusttunnel
        exit 0
    fi
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        echo "Использование:"
        echo "  bash setup_trusttunnel_v2.sh               Интерактивное меню управления"
        echo "  bash setup_trusttunnel_v2.sh --uninstall   Полностью удалить TrustTunnel"
        exit 0
    fi

    check_root
    check_tty
    show_main_menu
}

main "$@"
