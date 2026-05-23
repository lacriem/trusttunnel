# TrustTunnel VPN Manager v2

Автоматический скрипт для развёртывания и управления [TrustTunnel](https://github.com/TrustTunnel/TrustTunnel) VPN на Ubuntu/Debian.

## Возможности

- **Интерактивное меню** — управление всеми аспектами VPN из единого интерфейса
- **Полная установка** — развёртывание TrustTunnel одной командой
- **Пресеты конфигурации** — mobile / performance / stealth / balanced в один клик
- **GPG-верификация** — проверка подписи бинарника ключом AdGuard (с v0.9.126)
- **Управление пользователями** — добавление, удаление, смена пароля, экспорт конфигов и QR-кодов
- **Сертификаты** — выпуск, автообновление, проверка срока действия, информация (openssl)
- **Управление сервисом** — запуск/остановка/перезапуск, логи, мониторинг портов
- **Автообновление** — ежедневная проверка и установка новых версий TrustTunnel
- **Полное удаление** — очистка всех следов: конфиги, сервисы, сертификаты, кэш apt
- **Firewall** — автоматическая настройка UFW/iptables

## Требования

- ОС: **Ubuntu** или **Debian**
- **Root**-доступ (`sudo su`)
- **Домен**, A-запись которого указывает на IP сервера
- Открытые порты **80** (Certbot) и выбранный порт VPN

## Быстрый старт

### Однострочная установка (скачать и запустить)

```bash
rm -f setup_trusttunnel_v2.sh && curl -fsSL -O https://raw.githubusercontent.com/lacriem/trusttunnel/master/setup_trusttunnel_v2.sh && sudo bash setup_trusttunnel_v2.sh
```

Или по шагам:

```bash
sudo su
rm -f setup_trusttunnel_v2.sh
curl -fsSL -O https://raw.githubusercontent.com/lacriem/trusttunnel/master/setup_trusttunnel_v2.sh
bash setup_trusttunnel_v2.sh
```

Скрипт запускает интерактивное меню. Для установки выберите пункт **1**.

### CLI-аргументы

```bash
bash setup_trusttunnel_v2.sh               # Интерактивное меню
bash setup_trusttunnel_v2.sh --uninstall   # Полное удаление без меню
bash setup_trusttunnel_v2.sh --help        # Справка
```

## Меню

```
    ╔══════════════════════════════════════════════╗
    ║  ▓▓▓ TRUSTTUNNEL VPN MANAGER v2 ▓▓▓          ║
    ╚══════════════════════════════════════════════╝

  1) Установить / переустановить TrustTunnel
  2) Настройка (пресеты / правила / конфигурация)
  3) Пользователи (добавить / удалить / пароль / экспорт)
  4) Сертификаты (статус / продление / информация)
  5) Сервис (запуск / остановка / логи / порты)
  6) Обновить TrustTunnel
  7) Статус системы
  8) Полное удаление TrustTunnel
  0) Выход
```

## Пресеты конфигурации

| Пресет | Описание | Ключевые параметры |
|---|---|---|
| **mobile** | Оптимизация для 4G/5G, нестабильных соединений | Низкие таймауты, 256 streams, 50 MB conn window |
| **performance** | Для гигабитных каналов и высоконагруженных серверов | 2000 streams, 16 MB conn window, 512 KB stream window |
| **stealth** | Маскировка под обычный HTTPS, обход DPI | 100 streams, малый frame size, 0-RTT выкл |
| **balanced** | Сбалансированные значения (рекомендуется) | 1000 streams, 8 MB conn window, 0-RTT выкл |

## Безопасность (hardening)

| Параметр | Значение | Обоснование |
|---|---|---|
| `enable_early_data` | `false` | Защита от QUIC 0-RTT replay-атак (RFC 9000) |
| `tcp_connections_timeout_secs` | `7200` (2ч) | Предотвращает истощение ресурсов (PROTOCOL.md) |
| `max_frame_size` (HTTP/2) | `65536` | RFC 7540 §6.5.2 рекомендует для производительности |
| `allow_private_network_connections` | `false` | Изоляция приватных сетей endpoint |
| `upload_buffer_size` (HTTP/1) | `65536` | Оптимальный размер буфера |
| `rules.toml` | Предупреждение о default-allow | Напоминание настроить фильтрацию и catch-all deny |
| **GPG-верификация** | Ключ AdGuard `28645AC9...` | Проверка подписи бинарника (VERIFY_RELEASES.md) |
| Пароли | `chmod 600`, 16-символьные | Локальная защита + достаточная энтропия |

## Структура файлов

```
/opt/trusttunnel/                  # Рабочая директория TrustTunnel
├── trusttunnel_endpoint           # Бинарник (GPG-верифицирован)
├── credentials.toml               # Учётные данные (chmod 600)
├── vpn.toml                       # Конфигурация VPN-сервера
├── hosts.toml                     # TLS-хосты и сертификаты
├── rules.toml                     # Правила фильтрации подключений
├── backups/                       # Автоматические бэкапы конфигов
└── trusttunnel-auto-update.sh     # Скрипт автообновления

/root/
├── trusttunnel_clients.txt        # Сводка по клиентам
└── *_trusttunnel.toml             # Клиентские конфигурации
```

## Лицензия

Скрипт распространяется как есть. TrustTunnel — проект с открытым исходным кодом: [github.com/TrustTunnel/TrustTunnel](https://github.com/TrustTunnel/TrustTunnel)
