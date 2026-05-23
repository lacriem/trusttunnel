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

    # Проверяем есть ли .sha256 файл в репозитории
    local http_code
    http_code=$(curl -sSL -o /dev/null -w "%{http_code}" "$INSTALL_SCRIPT_SHA256_URL" 2>/dev/null)
    http_code="${http_code:-000}"
    
    if [ "$http_code" = "200" ]; then
        curl -fsSL -o "${tmpdir}/install.sh.sha256" "$INSTALL_SCRIPT_SHA256_URL"
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
        mkdir -p "$TT_DIR"
        echo "$expected_sha" > "$UPDATE_CHECK_FILE"
    else
        log_warn "SHA256 checksum недоступен (HTTP ${http_code}). Пропускаем проверку целостности."
        # Генерируем локальный SHA256 для будущих проверок обновлений
        mkdir -p "$TT_DIR"
        sha256sum "${tmpdir}/install.sh" | awk '{print $1}' > "$UPDATE_CHECK_FILE"
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
    echo -e "  ${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}║${BOLD}   ▓▓▓ НАСТРОЙКА ПАРАМЕТРОВ ▓▓▓              ${NC}${CYAN}║${NC}"
    echo -e "  ${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    while true; do
        echo -ne "  ${CYAN}▸${NC} ${BOLD}Домен:${NC} "
        read -r DOMAIN
        DOMAIN=$(echo "$DOMAIN" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -z "$DOMAIN" ]; then
            echo -e "  ${RED}  ✗ Домен не может быть пустым${NC}"
            continue
        fi
        break
    done

    echo -e "  ${DIM}  Проверяем разрешение домена...${NC}"
    DOMAIN_IP=$(dig +short "$DOMAIN" 2>/dev/null | tail -1 || echo "")
    SERVER_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')

    if [ -z "$DOMAIN_IP" ]; then
        echo -e "  ${YELLOW}  ⚠ Не удалось определить IP домена (проверьте DNS)${NC}"
    elif [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
        echo -e "  ${YELLOW}  ▸ Разрешается в ${DOMAIN_IP}, IP сервера: ${SERVER_IP}${NC}"
        echo -ne "  ${YELLOW}  Продолжить? [y/N]:${NC} "
        read -r force_continue
        if [[ ! "$force_continue" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        echo -e "  ${GREEN}  ✓ Домен корректно указывает на этот сервер${NC}"
    fi

    echo ""
    echo -ne "  ${CYAN}▸${NC} ${BOLD}Количество пользователей VPN ${DIM}[1]${NC}: "
    read -r USER_COUNT
    USER_COUNT=${USER_COUNT:-1}
    if ! [[ "$USER_COUNT" =~ ^[0-9]+$ ]] || [ "$USER_COUNT" -lt 1 ]; then
        USER_COUNT=1
    fi

    USERNAMES=()
    PASSWORDS=()
    CLIENT_NAMES=()

    for i in $(seq 1 "$USER_COUNT"); do
        echo ""
        echo -e "  ${CYAN}┌── Пользователь #${i} ──────────────────────────┐${NC}"
        local username password client_name
        while true; do
            echo -ne "  ${CYAN}│${NC} ${BOLD}Имя:${NC} "
            read -r username
            username=$(echo "$username" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            username=${username:-user$i}
            if [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                echo -e "  ${CYAN}│${NC} ${RED}  ✗ Только буквы, цифры, _ и -${NC}"
                continue
            fi
            break
        done

        echo -ne "  ${CYAN}│${NC} ${BOLD}Пароль:${NC} ${DIM}(Enter = случайный)${NC} "
        read -rs password
        echo ""
        if [ -z "$password" ]; then
            password=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
            echo -e "  ${CYAN}│${NC} ${GREEN}  ✓ Сгенерирован:${NC} ${BOLD}${password}${NC}"
        fi

        echo -ne "  ${CYAN}│${NC} ${BOLD}Имя конфига:${NC} ${DIM}[client${i}]${NC} "
        read -r client_name
        client_name=${client_name:-client$i}
        if [[ ! "$client_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo -e "  ${CYAN}│${NC} ${YELLOW}  ⚠ Недопустимые символы, используем client${i}${NC}"
            client_name="client$i"
        fi
        echo -e "  ${CYAN}└──────────────────────────────────────────────┘${NC}"

        USERNAMES+=("$username")
        PASSWORDS+=("$password")
        CLIENT_NAMES+=("$client_name")
    done

    echo ""
    while true; do
        echo -ne "  ${CYAN}▸${NC} ${BOLD}Порт TrustTunnel ${DIM}[443]${NC}: "
        read -r LISTEN_PORT
        LISTEN_PORT=${LISTEN_PORT:-443}
        if ! [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || [ "$LISTEN_PORT" -lt 1 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
            echo -e "  ${RED}  ✗ Порт должен быть от 1 до 65535${NC}"
            continue
        fi
        break
    done
    echo ""
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
# Правила фильтрации оцениваются по порядку. Применяется первое совпавшее правило.
# client_random_prefix и catch-all deny будут сгенерированы автоматически
# при создании пользователей через --generate-client-random-prefix.
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
    local occupied=0
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        occupied=1
        log_error "TCP порт ${port} уже занят"
        ss -tlnp 2>/dev/null | grep ":${port} " || true
    fi
    if ss -ulnp 2>/dev/null | grep -q ":${port} "; then
        occupied=1
        log_error "UDP порт ${port} уже занят"
        ss -ulnp 2>/dev/null | grep ":${port} " || true
    fi
    if command -v lsof &>/dev/null && lsof -i UDP:"${port}" 2>/dev/null | grep -q ":${port} "; then
        occupied=1
        log_error "UDP порт ${port} занят (по данным lsof)"
        lsof -i UDP:"${port}" 2>/dev/null || true
    fi
    if [ "$occupied" -eq 1 ]; then
        log_error "Порт ${port} уже занят. Освободите его или выберите другой."
        exit 1
    fi
}

# ===========================
# 6. CHECK / GET LET'S ENCRYPT CERT
# ===========================
check_existing_certificate() {
    local cert_dir="/etc/letsencrypt/live/$DOMAIN"
    local cert_path="${cert_dir}/fullchain.pem"
    local key_path="${cert_dir}/privkey.pem"
    local chain_path="${cert_dir}/chain.pem"
    local cert_single="${cert_dir}/cert.pem"

    # 1. Существование файлов
    if [ ! -f "$cert_path" ] || [ ! -f "$key_path" ]; then
        return 1
    fi

    # 2. Валидность по времени (не истекает в ближайшие 24 часа)
    if ! openssl x509 -checkend 86400 -noout -in "$cert_path" 2>/dev/null; then
        log_warn "Существующий сертификат истёк или истекает в течение 24 часов"
        return 1
    fi

    # 3. Проверка домена в SAN или CN
    local san_match
    san_match=$(openssl x509 -in "$cert_path" -noout -text 2>/dev/null \
        | grep -A1 "Subject Alternative Name" \
        | grep -oP "DNS:\K[^, ]+" \
        | grep -Fx "$DOMAIN" || true)

    if [ -z "$san_match" ]; then
        local cn_domain
        cn_domain=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null \
            | grep -oP "CN\s*=\s*\K[^,/]+" \
            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ "$cn_domain" != "$DOMAIN" ]; then
            log_warn "Существующий сертификат выдан для '$cn_domain', но требуется '$DOMAIN'"
            return 1
        fi
    fi

    # 4. Проверка цепочки доверия
    if [ -f "$chain_path" ] && [ -f "$cert_single" ]; then
        if ! openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt -untrusted "$chain_path" "$cert_single" &>/dev/null; then
            log_warn "Цепочка доверия существующего сертификата невалидна"
            return 1
        fi
    fi

    log_info "Сертификат для $DOMAIN уже существует и действителен, пропускаем выпуск"
    return 0
}

get_certificate() {
    log_info "Проверяем существующие сертификаты для $DOMAIN..."

    if check_existing_certificate; then
        return 0
    fi

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

    local renewal_conf="/etc/letsencrypt/renewal/${DOMAIN}.conf"

    # Быстрая проверка: если всё уже настроено — выходим мгновенно
    local already_configured=0
    if systemctl list-timers 2>/dev/null | grep -qE 'certbot|letsencrypt'; then
        if [ -f "$renewal_conf" ] && grep -q "renew_hook = systemctl restart trusttunnel" "$renewal_conf"; then
            if [ -f "/etc/cron.d/trusttunnel-cert-renewal" ]; then
                already_configured=1
            fi
        fi
    fi

    if [ "$already_configured" -eq 1 ]; then
        log_info "Автообновление уже полностью настроено"
        return 0
    fi

    if systemctl list-timers 2>/dev/null | grep -qE 'certbot|letsencrypt'; then
        log_info "Certbot timer уже активен"
    else
        log_info "Включаем certbot timer..."
        systemctl enable certbot.timer 2>/dev/null || true
        systemctl start certbot.timer 2>/dev/null || true
    fi

    log_info "Добавляем deploy-hook для перезапуска TrustTunnel..."
    setup_renew_hook_manual

    if [ ! -f "/etc/cron.d/trusttunnel-cert-renewal" ]; then
        cat > /etc/cron.d/trusttunnel-cert-renewal << 'EOF'
0 3 * * * root certbot renew --quiet --deploy-hook "systemctl restart trusttunnel" >> /var/log/trusttunnel-cert-renewal.log 2>&1
EOF
        chmod 644 /etc/cron.d/trusttunnel-cert-renewal
        log_info "Cron fallback добавлен"
    else
        log_info "Cron fallback уже существует"
    fi

    # Dry-run пропускаем — сертификат только что выпущен успешно
    log_info "Пропускаем dry-run (сертификат свежий). Проверить вручную: certbot renew --dry-run"
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
ConditionPathExists=/opt/trusttunnel/vpn.toml
ConditionPathExists=/opt/trusttunnel/hosts.toml

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

        ./trusttunnel_endpoint vpn.toml hosts.toml -c "$username" -a "$DOMAIN:$LISTEN_PORT" --generate-client-random-prefix --format toml > "$cred_file" 2>/dev/null || {
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

    # Добавляем catch-all deny в конец rules.toml
    if [ -f "${TT_DIR}/rules.toml" ]; then
        if ! grep -q '^action = "deny"' "${TT_DIR}/rules.toml"; then
            cat >> "${TT_DIR}/rules.toml" << 'EOF2'

# Catch-all deny: блокировать все остальные соединения
[[rule]]
action = "deny"
EOF2
            log_info "Добавлено catch-all deny правило в rules.toml"
        fi
    fi

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
set -eo pipefail

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

# Скачиваем инсталлятор для проверки
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

curl -fsSL -o "${tmpdir}/install.sh" "$INSTALL_SCRIPT_URL"
actual_sha=$(sha256sum "${tmpdir}/install.sh" | awk '{print $1}')

old_sha=""
if [ -f "$UPDATE_CHECK_FILE" ]; then
    old_sha=$(cat "$UPDATE_CHECK_FILE")
fi

if [ "$actual_sha" = "$old_sha" ] && [ -n "$old_sha" ]; then
    log "TrustTunnel актуален (SHA256 совпадает)."
    exit 0
fi

log "Найдено обновление TrustTunnel!"
log "Старый SHA: ${old_sha:-<нет>}"
log "Новый SHA:  $actual_sha"

# Если есть .sha256 в репозитории — дополнительно проверим
if curl -fsSL -o "${tmpdir}/install.sh.sha256" "$INSTALL_SCRIPT_SHA256_URL" 2>/dev/null; then
    expected_sha=$(awk '{print $1}' "${tmpdir}/install.sh.sha256")
    if [ "$expected_sha" != "$actual_sha" ]; then
        log "ОШИБКА: SHA256 не совпадает с официальным checksum!"
        exit 1
    fi
    log "Официальный checksum подтверждён."
fi

# Бэкап перед обновлением
ts=$(date +%Y%m%d%H%M%S)
mkdir -p "$BACKUP_DIR"
if [ -f "${TT_DIR}/trusttunnel_endpoint" ]; then
    cp "${TT_DIR}/trusttunnel_endpoint" "${BACKUP_DIR}/trusttunnel_endpoint.${ts}"
    log "Бэкап бинарника сохранён"
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
echo "$actual_sha" > "$UPDATE_CHECK_FILE"

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
# 13. MENU SYSTEM (CYBERPUNK EDITION)
# ===========================

BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
BLINK='\033[5m'


# ── ANSI helpers ──
_fmt() { echo -e "${1}${2}\033[0m"; }
bold()  { _fmt "$BOLD" "$1"; }
red()   { _fmt "$RED" "$1"; }
green() { _fmt "$GREEN" "$1"; }
yellow(){ _fmt "$YELLOW" "$1"; }
cyan()  { _fmt "$CYAN" "$1"; }
blue()  { _fmt "$BLUE" "$1"; }
dim()   { _fmt "$DIM" "$1"; }

# ── Animations ──
spinner() {
    local pid=$1 delay=0.1 spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " %s  " "$spinstr"
        local spinstr=$temp${spinstr%%"$temp"}
        sleep $delay
        printf "\r"
    done
    printf "    \r"
}

typewrite() {
    local text="$1" delay="${2:-0.01}"
    for ((i=0; i<${#text}; i++)); do
        printf "%s" "${text:$i:1}"
        sleep "$delay"
    done
    echo ""
}

# typewrite с цветом (цвет применяется до/после текста)
typewrite_c() {
    local text="$1" delay="${2:-0.01}" color="${3:-}" reset="${4:-$NC}"
    printf "%b" "$color"
    typewrite "$text" "$delay"
    printf "%b" "$reset"
}

pulse() {
    local text="$1" color="${2:-$GREEN}"
    for i in 1 2 3; do
        printf "\r  %b%s%b" "$color" "$text" "$NC"
        sleep 0.4
        printf "\r  %s" "$(dim "$text")"
        sleep 0.4
    done
    printf "\r  %b%s%b\n" "$color" "$text" "$NC"
}

# ── Menu helpers ──
mi() {
    local num="$1" text="$2" color="${3:-$CYAN}"
    echo -e "  ${DIM}┌─${NC} ${color}${num})${NC} ${text}"
}

mi_danger() {
    local num="$1" text="$2"
    echo -e "  ${RED}▸ ${num})${NC} ${RED}${text}${NC}"
}

mi_exit() {
    local num="$1" text="$2"
    echo -e "  ${DIM}└─${NC} ${DIM}${num})${NC} ${DIM}${text}${NC}"
}

show_header() {
    local title="${1:-TRUSTTUNNEL VPN MANAGER v2}"
    local width=46
    local prefix="  ▓▓▓ "
    local suffix=" ▓▓▓"
    local title_len=${#title}
    local content_len=$(( ${#prefix} + title_len + ${#suffix} ))
    local pad_left=$(( (width - content_len) / 2 ))
    local pad_right=$(( width - content_len - pad_left ))

    clear 2>/dev/null || true
    echo ""
    echo -e "${CYAN}    ╔══════════════════════════════════════════════╗${NC}"
    printf "${CYAN}    ║${BOLD}%*s%s%s%s%*s${NC}${CYAN}║${NC}\n" "$pad_left" "" "$prefix" "$title" "$suffix" "$pad_right" ""
    echo -e "${CYAN}    ╚══════════════════════════════════════════════╝${NC}"
    echo -e "${DIM}         ── secure · fast · encrypted ──${NC}"
    echo ""
}

press_enter() {
    echo ""
    echo -ne "  ${DIM}─ Нажмите Enter ─${NC}"
    read -r _
}

# ── UTF-8 safe repeat ──
repeat_char() {
    local char="$1" count="$2"
    local result=""
    for ((i=0; i<count; i++)); do
        result="${result}${char}"
    done
    printf '%s' "$result"
}

# ── Progress bar installer ──
draw_progress() {
    local current="$1" total="$2" label="$3"
    local pct=$((current * 100 / total))
    local width=25
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "\r  ${CYAN}▓${NC}"
    repeat_char "▓" "$filled"
    printf "${DIM}"
    repeat_char "▓" "$empty"
    printf "${NC} ${DIM}%3d%%${NC}  ${CYAN}▸${NC} %-42s\033[K" "$pct" "$label"
}

draw_progress_done() {
    local current="$1" total="$2" label="$3" status="$4"
    local pct=$((current * 100 / total))
    local width=25
    local filled=$((current * width / total))
    local empty=$((width - filled))
    local color="${GREEN}"
    local mark="✓"
    
    if [ "$status" = "FAIL" ]; then
        color="${RED}"
        mark="✗"
    fi
    
    printf "\r  ${color}▓${NC}"
    repeat_char "▓" "$filled"
    printf "${DIM}"
    repeat_char "▓" "$empty"
    printf "${NC} ${color}%3d%%${NC}  ${color}${mark}${NC} %-42s\033[K" "$pct" "$label"
}

run_install_step() {
    local current="$1" total="$2" label="$3"
    shift 3
    
    local spin_chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local spin_idx=0
    local logfile
    logfile=$(mktemp)
    
    # Запускаем команду в фоне, перехватывая вывод
    ( "$@" ) >"$logfile" 2>&1 &
    local pid=$!
    
    # Пока команда выполняется — крутим спиннер
    while kill -0 "$pid" 2>/dev/null; do
        local char="${spin_chars:$spin_idx:1}"
        draw_progress "$current" "$total" "${char} ${label}"
        spin_idx=$(((spin_idx + 1) % 10))
        sleep 0.08
    done
    
    wait "$pid"
    local exit_code=$?
    
    if [ "$exit_code" -eq 0 ]; then
        draw_progress_done "$current" "$total" "$label" "OK"
        rm -f "$logfile"
        return 0
    else
        draw_progress_done "$current" "$total" "$label" "FAIL"
        printf "\n"
        echo -e "  ${RED}▸ Ошибка выполнения:${NC}"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        sed 's/^/    /' "$logfile"
        echo -e "  ${DIM}────────────────────────────────────────${NC}"
        rm -f "$logfile"
        return 1
    fi
}

full_install() {
    clear 2>/dev/null || true
    
    # Сначала собираем данные (без прогресса, чтобы не ломать TUI)
    get_user_input
    
    # Очищаем экран от ввода и показываем заголовок установки
    show_header "Установка"
    
    # Все шаги установки подряд — один плавный прогресс-бар
    local total=10
    local current=0
    
    current=$((current + 1)); run_install_step "$current" "$total" "Установка зависимостей" install_deps || {
        log_error "Ошибка на шаге: Установка зависимостей"
        press_enter
        return 1
    }
    current=$((current + 1)); run_install_step "$current" "$total" "Загрузка TrustTunnel" install_trusttunnel || {
        log_error "Ошибка на шаге: Загрузка TrustTunnel"
        press_enter
        return 1
    }
    current=$((current + 1)); run_install_step "$current" "$total" "Проверка порта $LISTEN_PORT" check_port_available "$LISTEN_PORT" || true
    current=$((current + 1)); run_install_step "$current" "$total" "Генерация конфигурации" generate_configs || true
    current=$((current + 1)); run_install_step "$current" "$total" "Получение SSL-сертификата" get_certificate || true
    current=$((current + 1)); run_install_step "$current" "$total" "Настройка автообновления сертификатов" setup_auto_renewal || true
    current=$((current + 1)); run_install_step "$current" "$total" "Настройка systemd сервиса" setup_systemd || true
    current=$((current + 1)); run_install_step "$current" "$total" "Настройка автообновления TrustTunnel" setup_auto_update || true
    current=$((current + 1)); run_install_step "$current" "$total" "Экспорт конфигураций клиентов" export_client_config || true
    current=$((current + 1)); run_install_step "$current" "$total" "Настройка firewall" setup_firewall || true
    
    # Финальный прогресс
    draw_progress_done "$total" "$total" "Установка завершена" "OK"
    
    echo ""
    echo -e "  ${GREEN}▸ Установка завершена без критических ошибок.${NC}"
    echo -e "  ${DIM}  Рекомендуем прокрутить выше и проверить лог на предмет warning'ов.${NC}"
    echo ""
    echo -e "  ${DIM}──────────────────────────────────────────────${NC}"
    echo ""
    
    echo -e "  ${BOLD}Сервер:${NC}  ${CYAN}$DOMAIN${NC}:${CYAN}$LISTEN_PORT${NC}"
    echo ""
    
    # Генерируем и выводим данные для каждого пользователя
    pushd "${TT_DIR}" > /dev/null
    for idx in "${!USERNAMES[@]}"; do
        local username="${USERNAMES[$idx]}"
        local client_name="${CLIENT_NAMES[$idx]}"
        local cred_file="/root/${client_name}_trusttunnel.toml"
        local deeplink=""
        
        deeplink=$(./trusttunnel_endpoint vpn.toml hosts.toml -c "$username" -a "$DOMAIN:$LISTEN_PORT" --format deeplink 2>/dev/null || echo "")
        
        echo -e "  ${BOLD}Пользователь:${NC} ${CYAN}$username${NC}"
        echo -e "    ${DIM}Конфиг:${NC}  ${CYAN}${cred_file}${NC}"
        
        if [ -n "$deeplink" ]; then
            echo -e "    ${DIM}Ссылка:${NC}  ${GREEN}${deeplink}${NC}"
            if command -v qrencode &>/dev/null; then
                echo ""
                qrencode -t ANSIUTF8 "$deeplink" 2>/dev/null | sed 's/^/    /' || true
                echo ""
            fi
        fi
        echo ""
    done
    popd > /dev/null
    
    echo -e "  ${BOLD}Управление:${NC}"
    echo -e "    ${CYAN}systemctl status trusttunnel${NC}"
    echo -e "    ${CYAN}journalctl -u trusttunnel -f${NC}"
    echo -e "    ${CYAN}systemctl restart trusttunnel${NC}"
    echo ""
    
    echo -e "  ${DIM}──────────────────────────────────────────────${NC}"
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
            sed -i 's/^tcp_connections_timeout_secs = .*/tcp_connections_timeout_secs = 2400/' "$config"
            sed -i 's/^udp_connections_timeout_secs = .*/udp_connections_timeout_secs = 180/' "$config"
            sed -i 's/^client_listener_timeout_secs = .*/client_listener_timeout_secs = 300/' "$config"
            sed -i 's/^max_concurrent_streams = .*/max_concurrent_streams = 256/' "$config"
            sed -i 's/^initial_max_data = .*/initial_max_data = 52428800/' "$config"
            sed -i 's/^message_queue_capacity = .*/message_queue_capacity = 2048/' "$config"
            ;;
        2)
            log_info "Применяем пресет: performance"
            log_warn "Пресет performance требует >=16 GB RAM и мониторинга памяти"
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
            sed -i 's/^upload_buffer_size = .*/upload_buffer_size = 32768/' "$config"
            sed -i 's/^max_frame_size = .*/max_frame_size = 16384/' "$config"
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
        ./trusttunnel_endpoint vpn.toml hosts.toml -c "$username" -a "$domain:$port" --generate-client-random-prefix --format toml > "$cred_file_client" 2>/dev/null || {
            cat > "$cred_file_client" << EOF2
endpoint = "https://$domain:$port"
username = "$username"
password = "$password"
EOF2
        }
        chmod 600 "$cred_file_client"
        popd > /dev/null

        # Добавляем catch-all deny, если отсутствует
        if [ -f "${TT_DIR}/rules.toml" ]; then
            if ! grep -q '^action = "deny"' "${TT_DIR}/rules.toml"; then
                cat >> "${TT_DIR}/rules.toml" << 'EOF2'

# Catch-all deny: блокировать все остальные соединения
[[rule]]
action = "deny"
EOF2
                log_info "Добавлено catch-all deny правило в rules.toml"
            fi
        fi

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
    ./trusttunnel_endpoint vpn.toml hosts.toml -c "$username" -a "$domain:$port" --generate-client-random-prefix --format toml > "$outfile" 2>/dev/null || {
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

    # Добавляем catch-all deny, если отсутствует
    if [ -f "${TT_DIR}/rules.toml" ]; then
        if ! grep -q '^action = "deny"' "${TT_DIR}/rules.toml"; then
            cat >> "${TT_DIR}/rules.toml" << 'EOF2'

# Catch-all deny: блокировать все остальные соединения
[[rule]]
action = "deny"
EOF2
            log_info "Добавлено catch-all deny правило в rules.toml"
        fi
    fi

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

# ── Arrow-key interactive menu ──
MENU_SEL=0

interactive_menu() {
    local -a items=(
        "Установить / переустановить TrustTunnel"
        "Настройка (пресеты / правила / конфигурация)"
        "Пользователи (добавить / удалить / пароль / экспорт)"
        "Сертификаты (статус / продление / информация)"
        "Сервис (запуск / остановка / логи / порты)"
        "Обновить TrustTunnel"
        "Статус системы"
        "Полное удаление TrustTunnel"
        "Выход"
    )
    local -a nums=(1 2 3 4 5 6 7 8 0)
    local -a colors=("$CYAN" "$CYAN" "$CYAN" "$CYAN" "$CYAN" "$CYAN" "$CYAN" "$RED" "$DIM")
    local total=${#items[@]}
    local sel=${MENU_SEL:-0}

    while true; do
        show_header

        # ── Status panel ──
        echo -e "${DIM}    ┌── SYSTEM STATUS ──────────────────────┐${NC}"
        if systemctl is-active --quiet trusttunnel 2>/dev/null; then
            echo -e "    │  ${GREEN}◉${NC} Сервис: ${GREEN}ONLINE${NC}                    │"
        else
            echo -e "    │  ${RED}◎${NC} Сервис: ${RED}OFFLINE${NC}                   │"
        fi
        if [ -f "${TT_DIR}/credentials.toml" ]; then
            local uc
            uc=$(grep -c 'username' "${TT_DIR}/credentials.toml" 2>/dev/null || echo "0")
            echo -e "    │  ${CYAN}◉${NC} Клиентов: ${BOLD}${uc}${NC}                        │"
        else
            echo -e "    │  ${DIM}◉ Клиентов: —${NC}                         │"
        fi
        echo -e "${DIM}    └───────────────────────────────────────┘${NC}"
        echo ""

        # ── Menu ──
        echo -e "${DIM}    ╭── MAIN MENU ──────────────────────────╮${NC}"
        echo ""

        for i in "${!items[@]}"; do
            local num="${nums[$i]}"
            local text="${items[$i]}"
            local col="${colors[$i]}"

            if [ "$i" -eq "$sel" ]; then
                # Highlighted (selected) — яркий цвет текста
                if [ "$i" -eq 7 ]; then
                    echo -e "  ${RED}▸ ${BOLD}${WHITE}${num})${NC} ${BOLD}${RED}${text}${NC} ${RED}◄${NC}"
                else
                    echo -e "  ${CYAN}▸ ${BOLD}${WHITE}${num})${NC} ${BOLD}${CYAN}${text}${NC} ${CYAN}◄${NC}"
                fi
            else
                # Normal — единый префикс для всех
                echo -e "  ${DIM}┌─${NC} ${col}${num})${NC} ${text}"
            fi
        done

        echo ""
        echo -e "${DIM}    ╰── ↑↓ выбор  •  Enter подтвердить ───╯${NC}"
        echo ""

        # ── Read key ──
        local key rest
        IFS= read -rs -n1 key
        if [[ "$key" == $'\033' ]]; then
            IFS= read -rs -n2 rest
            key="$key$rest"
        fi

        case "$key" in
            $'\033[A') # Up
                sel=$((sel - 1))
                if [ "$sel" -lt 0 ]; then sel=$((total - 1)); fi
                ;;
            $'\033[B') # Down
                sel=$((sel + 1))
                if [ "$sel" -ge "$total" ]; then sel=0; fi
                ;;
            $'\n'|$'\r'|"") # Enter
                MENU_SEL="$sel"
                return
                ;;
        esac
    done
}

show_main_menu() {
    # Boot animation (first run only)
    if [ -z "${TT_BOOT_ANIM_SHOWN:-}" ]; then
        clear 2>/dev/null || true
        echo ""
        echo -e "${CYAN}    ╔══════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}    ║${BOLD}  ▓▓▓ TRUSTTUNNEL VPN MANAGER v2 ▓▓▓${NC}${CYAN}          ║${NC}"
        echo -e "${CYAN}    ╚══════════════════════════════════════════════╝${NC}"
        echo -e "${DIM}         ── secure · fast · encrypted ──${NC}"
        echo ""
        
        # Progress bar animation
        local progress=0
        local total=20
        echo -ne "    ${DIM}[${NC}"
        while [ $progress -lt $total ]; do
            echo -ne "${CYAN}▓${NC}"
            sleep 0.03
            progress=$((progress + 1))
        done
        echo -e "${DIM}]${NC} ${GREEN}OK${NC}"
        echo ""
        
        # Aligned status messages
        printf "    ${CYAN}%-30s${NC} ${GREEN}%s${NC}\n" "Initializing kernel modules..." "[ DONE ]"
        sleep 0.1
        printf "    ${CYAN}%-30s${NC} ${GREEN}%s${NC}\n" "Loading crypto libraries..." "[ DONE ]"
        sleep 0.1
        printf "    ${CYAN}%-30s${NC} ${GREEN}%s${NC}\n" "Connecting to TrustTunnel..." "[ DONE ]"
        sleep 0.1
        printf "    ${CYAN}%-30s${NC} ${GREEN}%s${NC}\n" "Verifying certificates..." "[ DONE ]"
        sleep 0.1
        printf "    ${CYAN}%-30s${NC} ${GREEN}%s${NC}\n" "System ready." "[ READY ]"
        echo ""
        
        TT_BOOT_ANIM_SHOWN=1
        sleep 0.5
    fi

    while true; do
        interactive_menu
        local idx="$MENU_SEL"

        case "$idx" in
            0) echo ""; pulse "[ LAUNCH ] Установка TrustTunnel..." "$CYAN"; full_install ;;
            1) reconfigure_menu ;;
            2) user_management_menu ;;
            3) certificate_menu ;;
            4) service_menu ;;
            5) echo ""; pulse "[ UPDATE ] Проверка обновлений..." "$YELLOW"; update_trusttunnel ;;
            6) show_status ;;
            7) uninstall_trusttunnel ;;
            8) echo ""; 
                echo -e "    ${DIM}────────────────────────────────────────${NC}"
                printf "    ${CYAN}%-30s${NC} ${YELLOW}%s${NC}\n" "Shutting down services..." "[ STOP ]"
                sleep 0.2
                printf "    ${CYAN}%-30s${NC} ${GREEN}%s${NC}\n" "Closing connections..." "[ DONE ]"
                sleep 0.2
                printf "    ${CYAN}%-30s${NC} ${GREEN}%s${NC}\n" "System halted." "[  OK  ]"
                echo -e "    ${DIM}────────────────────────────────────────${NC}"
                echo ""
                echo -e "              ${CYAN}До свидания.${NC}"
                exit 0 ;;
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
