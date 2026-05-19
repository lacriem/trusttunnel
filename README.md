# TrustTunnel Auto-Setup

Автоматический скрипт для развёртывания [TrustTunnel](https://github.com/TrustTunnel/TrustTunnel) VPN на сервере с Ubuntu/Debian.

## Возможности

- **Полная автоматизация** — установка, настройка и запуск TrustTunnel одной командой
- **Let's Encrypt** — автоматический выпуск и продление TLS-сертификатов
- **Многопользовательский режим** — создание нескольких VPN-аккаунтов
- **QUIC и HTTP/2** — поддержка современных протоколов с настраиваемыми параметрами
- **Автообновление** — ежедневная проверка и автоматическое обновление бинарника TrustTunnel
- **QR-коды** — генерация QR-кодов для быстрого подключения с мобильных устройств
- **Firewall** — автоматическая настройка UFW/iptables

## Требования

- ОС: **Ubuntu** или **Debian**
- **Root**-доступ (`sudo su`)
- **Домен**, A-запись которого указывает на IP сервера
- Открытые порты **80** (для Certbot) и **443** (или другой выбранный порт для VPN)

## Быстрый старт

```bash
sudo su
bash setup_trusttunnel_v2.sh
```

Скрипт в интерактивном режиме запросит:

1. **Домен** — проверит DNS-разрешение и совпадение с IP сервера
2. **Количество пользователей** — сколько VPN-аккаунтов создать
3. **Имя и пароль** для каждого пользователя (пароль можно сгенерировать автоматически)
4. **Порт** для TrustTunnel (по умолчанию 443)

## Что делает скрипт

| Шаг | Описание |
|-----|----------|
| 1 | Установка зависимостей (certbot, qrencode, jq и др.) |
| 2 | Скачивание и установка TrustTunnel с проверкой SHA256 |
| 3 | Интерактивный ввод настроек |
| 4 | Генерация конфигурационных файлов (`credentials.toml`, `vpn.toml`, `hosts.toml`, `rules.toml`) |
| 5 | Проверка доступности порта |
| 6 | Выпуск Let's Encrypt сертификата (standalone или webroot) |
| 7 | Настройка автообновления сертификатов (certbot timer + cron fallback) |
| 8 | Создание systemd-сервиса `trusttunnel` |
| 9 | Генерация клиентских конфигураций с QR-кодами |
| 10 | Настройка firewall (UFW / iptables) |
| 11 | Настройка ежедневного автообновления TrustTunnel (systemd timer + cron fallback) |

## Структура файлов

```
/opt/trusttunnel/                  # Рабочая директория TrustTunnel
├── trusttunnel_endpoint           # Бинарник
├── credentials.toml               # Учётные данные пользователей (chmod 600)
├── vpn.toml                       # Конфигурация VPN-сервера
├── hosts.toml                     # Настройки хостов и TLS-сертификатов
├── rules.toml                     # Правила маршрутизации
├── backups/                       # Бэкапы конфигураций
└── trusttunnel-auto-update.sh     # Скрипт автообновления

/root/
├── trusttunnel_clients.txt        # Сводка по всем клиентам
├── client1_trusttunnel.toml       # Конфигурация для клиента 1
└── client2_trusttunnel.toml       # Конфигурация для клиента 2
```

## Управление

```bash
# Статус сервиса
systemctl status trusttunnel

# Логи сервиса
journalctl -u trusttunnel -f

# Логи обновлений
journalctl -u trusttunnel-update -f

# Ручное обновление
bash /opt/trusttunnel/trusttunnel-auto-update.sh

# Перезапуск
systemctl restart trusttunnel
```

## Безопасность

- `credentials.toml` создаётся с правами `600` (только root)
- Клиентские файлы в `/root/` также доступны только root
- SHA256-проверка инсталлятора перед запуском
- Бэкап текущего бинарника перед каждым обновлением
- Деплой-хук автоматически перезапускает TrustTunnel при обновлении сертификата

## SNI-маскировка

По умолчанию в `hosts.toml` задано `allowed_sni = ["time.android.com"]`, что маскирует VPN-трафик под обращение к службе времени Android.

## Лицензия

Скрипт распространяется как есть. TrustTunnel — проект с открытым исходным кодом: [github.com/TrustTunnel/TrustTunnel](https://github.com/TrustTunnel/TrustTunnel)