# GhostChat Backend — Security & Correctness Audit
_Дата: 2026-05-29. Аудит live-пути (`main_remote:app` + `database.py`)._

> ## СТАТУС ИСПРАВЛЕНИЙ (2026-05-29)
> **ЗАКРЫТО и проверено на проде:**
> - ✅ **C1** — 4 независимых секрета ротированы (JWT/INTERNAL/SUPPORT/ADMIN), `config.py` падает при старте без `GC_JWT_SECRET`, fallback убран. Старый секрет `297bed02…` отклоняется (401). Старые секреты СОЖЖЕНЫ — не переиспользовать.
> - ✅ **C2/C3** — код подтверждения генерит/сверяет СЕРВЕР (keyed-хэш), одобрение только аутентифицированным доверенным устройством, проверка expiry, лимит 5 попыток, миграция БД v3 (`code_hash`).
> - ✅ **H1** — `/internal/shop_login` теперь constant-time (`safe_equal`).
> - ✅ **H2** — username строго ASCII + резерв-имена; display_name 2..100 без zalgo/control/bidi; pubkey валидируется (base64 32 байта). Дублирует клиентские валидаторы.
> - ✅ **H4** — `relay_ack`/`relay_seen` scoped по `to_username == conn.username` (IDOR закрыт).
> - ✅ **legacy login bypass** — login требует device_id.
>
> **ОСТАЁТСЯ (по желанию):** H3 (channel set_keys), H5 (shop check_user), M1 (токен в query), M3 (pubkey-override в /api/profile → MITM, частично закрыто на register), M4 (upload в RAM), M5 (rate-limit /site/login), L1-L5. Подробности ниже.
>
> **TODO операционно:** вычистить старые секреты из git-истории (если репо), `.gitignore` для `.env`; локальная `shop/.env` всё ещё содержит BOT_TOKEN/OWNER_PASSWORD — не коммитить.

## Executive summary
Самая тяжёлая проблема — **катастрофа управления секретами (C1)**: JWT-секрет
не задан отдельно и молча падает на `GHOSTCHAT_SUPPORT_PASSWORD` = `GC_INTERNAL_KEY`
(одно и то же значение `297bed02…`), которое лежит в `shop/.env` и `deploy/*.service`
открытым текстом. Кто угодно с доступом к репо может **подделать валидный JWT для
ЛЮБОГО пользователя** и дёргать внутренние эндпоинты — полное уничтожение модели
аутентификации и анонимности. Вдобавок весь флоу подтверждения входа с нового
устройства (6-значный код) **не аутентифицирован и доверяет клиенту**.

Хорошее: параметризованный SQL везде, Argon2id, sealed-sender на WS (`from` берётся
из соединения, не от клиента), эфемерный X25519+AES-GCM на транспорте, метаданные
только в RAM.

> Мёртвый код (НЕ в проде, удалить): `main.py`, верхнеуровневый `auth.py`,
> `db_remote.py`, `routers/main_remote.py`, `*.save`. Живые роутеры — в `routers/`.

## Findings

| ID | Severity | Title | Location |
|----|----------|-------|----------|
| **C1** | CRITICAL | JWT-секрет = support password = internal key, лежит в репо. Подделка токена любого юзера | `config.py:21,29,32,35`; `deploy/ghostchat.service:7-9`; `shop/.env` |
| **C2** | CRITICAL | Подтверждение входа с нового устройства не аутентифицировано, код проверяет клиент | `routers/auth.py:194-234,164-191` |
| **C3** | CRITICAL | Нет защиты от брутфорса кода, гонки в attempt_count, expires_at не проверяется | `routers/auth.py:208-234`; `ws/handlers.py:671-690` |
| **H1** | HIGH | `/internal/shop_login`: сравнение ключа не constant-time | `routers/auth.py:82` |
| **H2** | HIGH | Username допускает Unicode (`str.isalnum()`) → homograph-спуфинг (аdmin). display_name/about/device_name только по длине → zalgo/RTL | `routers/auth.py:49` |
| **H3** | HIGH | `set_keys` канала: любой админ может перезаписать wrapped-key любого юзера (даже не члена) | `routers/channels.py:308-322` |
| **H4** | HIGH | IDOR: `relay_ack`/`relay_seen` ищут по `msg_id` без проверки `to_username==conn.username` → подделка квитанций, подавление сообщений | `ws/handlers.py:337-369` |
| **H5** | HIGH | shop_login шлёт пароль на `/api/login` без internal-key; legacy `check_user` принимает ключ в query string (логируется) | `shop/gc_db.py:31-37,86-90` |
| **M1** | MED | WS-токен в query (`?token=`) логируется; токен реплеится 90 дней; `did` не сверяется с device_id | `main_remote.py:193-200`; `ws/handlers.py:124-191` |
| **M2** | MED | JWT живёт 90 дней без ротации | `config.py:23` |
| **M3** | MED | Публичные ключи в `/api/profile` можно перезаписать произвольно → server-side MITM новых диалогов; нет валидации base64/длины | `routers/users.py:62-63` |
| **M4** | MED | `UploadFile.read()` грузит весь файл в RAM до проверки размера (DoS); лимиты рассинхронны (100/50/55 MB) | `routers/files.py:35-37` |
| **M5** | MED | `/api/site/login` без rate-limit → брутфорс/credential stuffing | `routers/shop.py:171-193` |
| **L1** | LOW | Снятие реакции: параметры DELETE перепутаны местами (функц. баг) | `ws/handlers.py:515-516` |
| **L2** | LOW | Регистрация различает «занято/неверный пароль» → enumeration | `routers/auth.py:54` |
| **L3** | LOW | `peer_status_req` отдаёт онлайн-статус любого юзера без проверки контактов | `ws/handlers.py:695-700` |
| **L4** | LOW | CORS пускает `http://localhost` и хардкод-IP | `main_remote.py:116-126` |
| **L5** | LOW | Мёртвый legacy-код со своими секретами и слабее крипто | `main.py`, `auth.py`, и т.д. |

## Top-5 приоритет
1. **C1** — 3 независимых высокоэнтропийных секрета, падать при старте если `GC_JWT_SECRET` не задан. Ротировать `297bed02…` и `463547e0…` (оба сожжены — были в репо), вычистить из git-истории, `.gitignore` для `.env`.
2. **C2+C3** — код генерит/проверяет СЕРВЕР, одобряет только аутентифицированное доверенное устройство, проверка expiry + атомарный счётчик попыток + ownership на все переходы.
3. **H4+H1** — scope `relay_ack`/`relay_seen` по `to_username==conn.username`; `safe_equal` в shop_login.
4. **H2+M3** — username только ASCII + резерв-имена; валидация/ограничение pubkey и display-полей; смена ключей = событие безопасности с уведомлением контактов (TOFU).
5. **M1+M5+M4** — токен только в заголовке, короче TTL, rate-limit на оба login, лимит upload по Content-Length + стриминг.

## Хорошие практики (уже есть)
- SQL параметризован везде (4 f-string места строят только имена колонок из серверных литералов — значения биндятся).
- Argon2id (m=64MB,t=2,p=2), rehash-on-login, generic "Invalid credentials".
- Sealed-sender на WS; эфемерный X25519→HKDF-SHA256→AES-256-GCM, свежий nonce, уничтожение приватного ключа после derive.
- Метаданные только в RAM, офлайн-сообщения удаляются при доставке.
- Constant-time сравнение для admin/internal/bypass; bypass-токен пуст по умолчанию.
- JWT с jti + token_min_iat (отзыв), `algorithms=[HS256]` запиннен.
