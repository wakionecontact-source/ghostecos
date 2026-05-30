# Changelog

Все заметные изменения в проекте документируются здесь.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
проект следует [Semantic Versioning](https://semver.org/lang/ru/).

## [Unreleased]

## [0.1.0] — 2026-05-30

Первый публичный релиз. AGPL-3.0.

### Добавлено

#### GhostChat (E2E-мессенджер)
- Web-клиент (vanilla JS) + Android APK
- E2E шифрование через Web Crypto API: P-256 ECDH + AES-256-GCM
- Приватный ключ хранится в IndexedDB как `CryptoKey` с `extractable=false`
  (XSS не может вытащить через `exportKey`)
- Transient storage: ciphertext на сервере только до доставки, затем DELETE
- TOFU pinning публичных ключей собеседников, предупреждение при смене
- Контакты, превью ссылок, превью постов GhostSocial
- WebSocket для realtime (typing, presence, новые сообщения)
- **Reply / Edit / Delete** через типизированный JSON-payload внутри ciphertext —
  сервер остаётся «слепым», вся логика на клиенте
- PWA — устанавливается как приложение на iOS/Android

#### GhostSocial (соцсеть)
- Лента постов с реакциями, комментариями, тегами, упоминаниями
- Алгоритмическая лента **на клиенте** (Algo) — сервер не знает интересы юзера
- Подписки, профили, шаринг
- **Миниски** — короткие вертикальные видео с авто-удалением через 48 часов
- Уведомления (real-time через WebSocket)
- Опросы и квизы

#### GhostBank (внутренняя экономика)
- 3 валюты: Gost (бесплатная активность), Soul (transferable, cap), Prem (премиум)
- Сезон 1 экономики, cap=100 000 Soul
- Формула курса Soul: `100 × cap / system_balance` (мин 100 Gost/Soul)
- 10 стартовых NFT от @ghostecos с анимациями (SVG keyframes)
- NFT-маркет: первичная продажа за Gost, P2P за Soul (10% комиссия)
- Передача NFT (1 Soul комиссия)
- Перевод Soul (3% комиссия)
- Invoices: создание (100 Gost), оплата (5% комиссия), 7 дней TTL
- Custom usernames (100 Soul, lifetime cap 3 на аккаунт, P2P-рынок 10/90%)
- Mint своего NFT (50 Gost + supply-fee, опц. автовыкуп системой за Soul)
- Минт поста в NFT прямо из GhostSocial

#### Безопасность
- Argon2id для паролей (PBKDF2 legacy с авто-апгрейдом)
- Rate-limits на всех write-эндпоинтах
- SQLite WAL + BEGIN IMMEDIATE для атомарности денежных транзакций
- HMAC-safe comparison для admin token
- Security headers (X-Frame-Options DENY, no-store на private, etc)
- CORS whitelist
- Seed-фразы для recovery аккаунта (16 символов, Argon2-hashed)

#### Инфраструктура
- README.md, SECURITY.md, LICENSE (AGPL-3.0)
- .env.example для shop/
- systemd units для деплоя
- nginx конфиг как референс

[Unreleased]: https://github.com/wakionecontact-source/ghostecos/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/wakionecontact-source/ghostecos/releases/tag/v0.1.0
