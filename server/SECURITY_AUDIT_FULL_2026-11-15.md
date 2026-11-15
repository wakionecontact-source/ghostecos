# Полный аудит безопасности GhostEcos — 2026-11-15

**Объект:** `ghostecos.duckdns.org` — бэкенд (`server/ghostecos-core`, `server/social`, `server/chat`), фронтенды (v2-чат Svelte, legacy-чат, соцсеть, банк, лендинг, `ghostauth`), приложение **GhostChat 1.2.2** (`app/ghostchat`, `version: 1.2.2+4122`), инфраструктура (nginx, systemd, Go-сервисы, GhoGem, shop).
**Метод:** статический анализ кода (6 параллельных проходов) + живая проверка заголовков/TLS/маршрутов и read-only инспекция сервера по SSH.
**Секреты не выводились и не сохранялись** — только факты вида `<set>` / маскировка.

---

## 0. Итог одной строкой

Ядро аутентификации и экономика написаны заметно аккуратнее, чем типичный пет-проект (Argon2id, SRP-подобный вход, device-bound JWT, `BEGIN IMMEDIATE`, TOFU, PKCE, параметризованный SQL). Но есть **пять мест, где вся эта аккуратность обнуляется**: legacy-вход выдаёт токен до проверки доверия устройству, WebSocket-ветка сохранения E2E-ключей обходит валидатор ключей, админ-токен экономики принимается из query, приложение хранит токен и переписку в открытом виде, а TDA/пароль-support опираются на значения по умолчанию.

| Severity | Кол-во |
|---|---|
| Critical | 6 |
| High | 14 |
| Medium | 17 |
| Low / Info | 20 |

---

## 1. Что проверено на живом сервере (факты, не выводы)

| Проверка | Результат |
|---|---|
| TLS | TLS 1.3, AES-256, сертификат `CN=ghostecos.duckdns.org` — норма |
| `Strict-Transport-Security` | отдаётся (`max-age=31536000; includeSubDomains`) |
| `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy` | отдаются на `/`, `/v2/chat`, `/gemo/`, `/info/` |
| CSP | есть только на `/` (`script-src 'self' 'unsafe-inline'` + cdnjs), **нет** на `/v2/chat`, `/gemo/`, `/info/` |
| `/.env`, `*.bak_*`, `auth.js.bak.*` | **404** — заявленная утечка бэкапов не подтвердилась (закрыто) |
| `/media/` | **403** (листинг закрыт) |
| `/api/soc/admin/stats` без токена | **401** — админка экономики fail-closed |
| `GE_ADMIN_TOKEN` в проде | **задан** → админ-эндпоинты экономики активны (риск API-01/02 реален) |
| Порты наружу | только 80/443/22/3478 (coturn); прикладные на `127.0.0.1` |
| SSH | `PasswordAuthentication no`, `MaxAuthTries 3`, ufw deny + fail2ban |
| Права | `/opt/ghostecos-core` — `750 root:ghostecos-app` (ок); `/opt/ghostchat` — `755 root` (код читаем локальными юзерами) |
| Юнит-файлы с секретами | `ghostchat.service`, `ghostsocial.service`, `ghostnation.service` — **600** (ок); проблема в drop-in'ах и `.env`-каталогах, см. INFRA-01/14 |
| Legacy-чат v1 | `/chat` → 301 `/v2/chat`, `/v1/chat` → **410** — legacy `chat/index.html` наружу **не отдаётся** |

---

## 2. CRITICAL

### C-1. Legacy-вход: токен выдаётся до проверки доверия устройству (AUTH-01)
`server/ghostecos-core/ecos_core/login.py:352-397`, `:225-231`
Если у пользователя есть пароль, но нет включённой TDA либо `trusted_count == 0`, устройство не проходит подтверждение — токен отдаётся сразу, а первое устройство становится `is_owner`.
**Последствия:** утечка/брутфорс пароля = полный доступ в обход второго фактора; фактически вся модель «доверенных устройств» обходится legacy-путём.
```python
if tda_on and (not already) and trusted_count > 0:   # иначе — сразу токен
    ... подтверждение ...
d = _da.register_device(c, u["id"], body.device_id, ..., is_owner=is_first_dev)
return {..., "token": d["token"], ...}
```
**Фикс:** требовать TDA для любого нового `device_id`; `is_owner` — только при регистрации; legacy-ветку `soc_tokens` (`:403-411`) удалить.

### C-2. WS-ветка `keys.upload` обходит валидатор E2E-ключей (CHAT-01 + CHAT-02)
`server/ghostecos-core/social_router.py:968` (обработчик), `:1777-1831` (мёртвый дубль)
HTTP-путь `chat_router.py:467` вызывает `key_security.validate_key_upload`; WS-путь — нет, проверяя лишь длину base64 (40–500 байт). В `users` пишутся `x25519_pub`, `encrypted_private_key`, `key_salt`, `key_kdf`, `key_format` без нормализации.
**Последствия:** любой залогиненный клиент перезаписывает публичный ключ произвольным значением → собеседники шифруют под ключ атакующего (downgrade/подмена), восстановление ключей ломается. Второй `elif t == "keys.upload"` — недостижимый код: любой патч «второй копии» не даёт эффекта.
**Фикс:** в WS вызывать `validate_key_upload` и писать только `checked[...]`; удалить все дубли обработчиков (`keys.me`, `devices.*`, `contacts.*`, `prof.get` тоже дублируются); тест паритета HTTP/WS.

### C-3. XSS + токен без HttpOnly в legacy-чате (FE-01 + FE-02)
`server/chat/index.html:1851` (`setSsoCookie` пишет `gs_token` в `document.cookie`), `:3778`, `:3378`, `:3070`
Токен сознательно дублируется в читаемую cookie на год; часть inline-обработчиков собирает `onclick` через `JSON.stringify(device_name)` без HTML-экранирования.
**Последствия:** любая инъекция (имя устройства, request_id из WS-пуша) → кража сессии на `/api/*`, `/bank`, `/social`.
**Смягчает:** наружу сейчас отдаётся v2-чат, legacy — 410. **Усугубляет:** файл остался в деплое и вернётся одной строкой конфига.
**Фикс:** cookie только серверная `HttpOnly; Secure; SameSite`, отдельный CSRF-токен; убрать legacy-файл из артефактов деплоя.

### C-4. Приложение: токен и переписка в открытом виде (APP-01 + APP-02)
`app/ghostchat/lib/services/auth_service.dart:180-196`, `db_service.dart`, `lan_chat_store.dart:185-209`
Токен `gs_token` пишется в обычные `SharedPreferences` при любой ошибке Keystore (ветка `catch` — штатная, не экзотика). Локальная SQLite (`ghost_$username.db`) и LAN-сообщения — без шифрования.
**Последствия:** `adb backup`/root/forensic-дамп = полная переписка, вложения, токен (доступ ко всему аккаунту). E2E на транспорте данные «в покое» не спасает.
**Фикс:** убрать fallback для токена; SQLCipher или шифрование полей + ключ из Keystore; миграция с `p.remove(_secureToken)`.

### C-5. Админ-токен экономики принимается из query (API-01 + API-02)
`server/ghostecos-core/social_router.py:9319`, `:8030`, `:9248`
```python
def giveaway_delete(gid: int, token: str = Query(...)):
    _check_admin_token(token)
```
**Последствия:** токен попадает в access-логи, `Referer`, историю браузера, кэши. `GE_ADMIN_TOKEN` в проде **задан**, а тот же секрет используется как пароль `/control/*` (`_control_password()`, `:6559`) — утечка даёт произвольную эмиссию Soul (`/admin/economy/emit`, `/grant`).
**Фикс:** только `X-Admin-Token`; отдельные секреты для control и economy; ротация; аудит-лог на эмиссию (сейчас `emit` не пишет `soc_wallet_tx` — API-14).

### C-6. Пароль поддержки по умолчанию в коде (INFRA-02)
`server/backchat/main.py:66`, `:1074`, `:1450`
```python
_SUPPORT_PASSWORD = _os.environ.get("GHOSTCHAT_SUPPORT_PASSWORD", "PER56712348727")
if key != _SUPPORT_PASSWORD:   # ещё и не constant-time
```
**Последствия:** значение навсегда в git-истории; при запуске без env — предсказуемый вход в поддержку и `/internal/check_user` (перечисление пользователей). Прод-юнит env задаёт, но дефолт остаётся ловушкой при любом новом деплое.
**Фикс:** убрать дефолт (fail-closed), `hmac.compare_digest`, вынести в env; отключить служебный аккаунт `hhh`.

---

## 3. HIGH

### Бэкенд: аутентификация
| ID | Место | Суть |
|---|---|---|
| H-1 | `routers/auth.py:290-373` | `poll_login_request` при `phase='success'` выдаёт **новый** JWT на каждый вызов; одноразовость не гарантирована (нужен CAS `UPDATE … WHERE phase='success'`) |
| H-2 | `ecos_core/sso.py:9-41` + `dependencies.py:56-58` | `/internal/v1/identity/sso/jwt` выпускает JWT без `did` и без `jti`; legacy-потребители (`decode_token_soft`) его принимают, `token_min_iat` не проверяется |
| H-3 | `ecos_core/account_access.py:83-93` | Recovery пишет токен в `soc_tokens` через `INSERT OR REPLACE`: плейнтекст, без TTL и ротации |
| H-4 | `waki_private_apk.py:174-185`, `waki_private_banner.py:20-31`, `chat_router` `_is_owner` | Владелец = `user.id == 2` — магическое число вместо роли; пересоздание БД отдаёт приватные страницы чужому |
| H-5 | `social_router.py:3194`, `shop/web/api.py:48` | `_client_ip` берёт **первый** элемент `X-Forwarded-For` (подделываемый) → обход per-endpoint лимитов; в middleware при этом берётся последний — расхождение |
| H-6 | `security.py:135-152` | `X-Real-IP` доверяется всегда, когда peer — loopback (а за nginx он всегда loopback) |

### Бэкенд: чат и ключи
| ID | Место | Суть |
|---|---|---|
| H-7 | `chat_router.py:995-1074` | `keysync` не сверяет `owner_user_id` ни в `poll`, ни в `post`, ни в `close`; `lookup` без rate-limit → подмена стороны ECDH при QR-синхронизации ключей |
| H-8 | `chat_router.py:405-413` | `device_id` берётся из клиентского `X-Device-Id` без привязки к токену; фильтр «не доставлено» — `LIKE '%"id"%'` |
| H-9 | `social_router.py:535` | `/api/soc/ws` без лимита размера кадра (в `chat_client_bridge` и bot-WS лимиты есть) → DoS на event-loop, `b64decode` до проверки длины |
| H-10 | `bot_api.py:1153` + `bot_runner_crypto.py:69` | `/api/bots/internal/managed` отдаёт шифртексты токенов ботов по статическому HMAC без TTL; заголовок разрешён в CORS |
| H-11 | `chat_router.py:1250-1269` | `history_sealed` не применяет TTL/`delivered_to` — сервер хранит sealed-DM дольше заявленного («до доставки») |

### Бэкенд: API и экономика
| ID | Место | Суть |
|---|---|---|
| H-12 | `social_router.py:5328-5407` | SSRF в `/linkpreview`: DNS-резолв проверяется, запрос идёт заново (rebinding), редиректы без повторной проверки → `169.254.169.254` |
| H-13 | `social_router.py:6981-7030` | `/post/{id}/overwatch`: баланс проверяется вне транзакции (TOCTOU) + цикл «свой пост → награда модераторам» без cooldown |
| H-14 | `social_router.py:8851-8907` | `/nft/mint`: `auto_buy` платит до создания экземпляров; нет суточного cap → опустошение `system_balance`, батч-вставка 10k строк |
| H-15 | `social_router.py:3547-3574` | `/upload`: тип определяется по расширению/MIME, видео-аудио пишутся «как есть»; отдача `/media` без `Content-Disposition` → stored XSS при MIME-sniffing |

### Фронтенд (живые страницы)
| ID | Место | Суть |
|---|---|---|
| H-16 | `server/site/index.html:1198` | `pmHead.innerHTML = '<b>' + me.gc_username` без экранирования — XSS на origin, где лежит `gs_token` |
| H-17 | вcе фронты | Нет CSP на `/v2/chat`, `/social`, `/bank`; legacy и лендинг грузят cdnjs/jsdelivr **без SRI** (живой `/` отдаёт CSP с `'unsafe-inline'`) |
| H-18 | `chat/web/src/lib/auth/session.ts:104` | Токен v2 в `localStorage` (30+ дней), `credentials:'same-origin'` уже используется — можно перейти на HttpOnly-cookie |
| H-19 | `chat/web/src/lib/auth/device-keys.ts:16-20` | Seed устройства в IndexedDB сырым `ArrayBuffer` (в `vault.ts:92` для приватника сделано правильно — `CryptoKey extractable=false`) |

### Приложение
| ID | Место | Суть |
|---|---|---|
| H-20 | `main_shell.dart` (нет `FLAG_SECURE` нигде) | Скриншоты, запись экрана и превью в Recents для чатов и seed-фразы |
| H-21 | `settings_screen.dart:5087-5135` | Seed-фраза копируется в общесистемный clipboard без `EXTRA_IS_SENSITIVE` и автоочистки |
| H-22 | `update_service.dart:812-893` | Нет сверки SHA-256/`versionCode`/сертификата APK перед установкой (только https + системная подпись) |
| H-23 | `ws_client.dart:76-88` | Токен в query WebSocket → логи прокси, дампы, история |

### Инфраструктура
| ID | Место | Суть |
|---|---|---|
| H-24 | systemd drop-ins, `/root/ghogem/.env`, `.env`-каталоги | Секреты (`GE_ADMIN_TOKEN`, `GC_JWT_SECRET`, `GC_INTERNAL_KEY`, `NATION_INTERNAL_TOKEN`, `GHOGEM_PC_BRIDGE_TOKEN`, ключи LLM) в `Environment=`/каталогах; `GC_JWT_SECRET` общий для ghostchat/nation → подделка токенов; `/root/ghogem` — `755` |
| H-25 | nginx `auth_request` `/learn` (`ghostchat_live.conf:1248-1266`) | Не передаётся `Host` → Core видит `127.0.0.1:8010`; обход maintenance-гейта |
| H-26 | `ghostecos-maint-access.conf` + `:60-66` | Cookie `gs_dev` с фиксированным SHA-256 — второй пропуск профилактики, противоречит собственному комментарию; значение лежит в бэкап-конфигах |
| H-27 | `nginx.conf` | `ssl_protocols 1.2/1.3`, `ssl_prefer_server_ciphers on`, но `ssl_ciphers` не задан; OCSP stapling выключен |
| H-28 | `location /download/` (`:752`), `/media/`, `/social/media/` | Свои `add_header`/alias **сбрасывают** унаследованные заголовки: нет `nosniff`/CSP на части локаций |
| H-29 | `shop` (`api.py:48`, `main.py`) | `forwarded_allow_ips="*"`, первый XFF как IP, `RATE_LIMIT_ENABLED=false`, `/shop/` в nginx без `limit_req` → перебор паролей |
| H-30 | `ghogem/web_api.py:1764` | Публичный мини-чат запускает агентский турн с общим UID и **без allow-list инструментов** → prompt injection к `write_file`/`read_file`, расход общих ключей |
| H-31 | `infra`: `96.126.129.193` | Один IP исключён из `limit_req`/`limit_conn` и одновременно входит в maint/`/test/`/`/social/admin` allow-списки |
| H-32 | `ghostsound/main.go:243-244` | `GET /v2/sound/admin` отдаёт `admin.html` без проверки авторизации (сам API закрыт) |
| H-33 | `code_ota.py:1044-1101`, `:1018` | `upload_token` без TTL и не гасится после загрузки; артефакты/патчи скачиваются публично; `GC_CODE_OTA_REQUIRE_SIGNATURE=0` разрешает патчи без подписи |

---

## 4. MEDIUM (кратко)

- **M-1** `security.py:223` — `JWT_SECRET` используется как pepper для кодов устройства и 6-значных кодов (нет отдельного ключа, ротация ломает pending).
- **M-2** `social_router.py:6266` — `/me/reports/incoming` раскрывает личности репортёров (преследование), Prem списывается до запроса.
- **M-3** `social_router.py:4090`, `:5625` — `/post/{id}` и OG отдают посты авторов с `profile_hidden`; OG-кэш живёт час после удаления миниски.
- **M-4** `social_router.py:7075` — голосование overwatch без `BEGIN IMMEDIATE` и rate-limit: возможен двойной расчёт награды.
- **M-5** `social_router.py:7426` — `/miniska/new` удаляет файл по чужому `video_url` при превышении длительности.
- **M-6** `social_router.py:8039` — `/admin/economy/emit` молча обнуляет отрицательный баланс и не пишет аудит-лог.
- **M-7** `room_router_v2.py:1797` — список инвайт-ссылок отдаёт **сырые токены**, включая деактивированные; `redeem` не атомарен (TOCTOU на `max_uses`).
- **M-8** `room_router_v2.py:1126` — точный поиск/превью private-комнат без членства раскрывает название, bio, аватар, счётчик.
- **M-9** `chat_router.py:2192` — `group_send` принимает `envelope_keys` для неучастников и отрицательных id.
- **M-10** `chat_router.py:1882` — `file_ack` удаляет `file_path` без проверки `commonpath` (в room-пути проверка есть).
- **M-11** `chat_router.py:113-124` — `UPDATE user_privacy SET {field}=?` f-string по имени колонки (сейчас недостижимо, но паттерн опасен).
- **M-12** `chat_router.py:883` — статус pending-логина отдаёт `granted_token` без rate-limit и без проверки `expires_at` до выдачи.
- **M-13** `support_admin_router.py:120` — переписка с поддержкой идёт `plain_text` (не E2E) без явной маркировки в UI.
- **M-14** `fcm_helper.py:43` — текст исключения FCM (может содержать registration token) пишется в лог.
- **M-15** `stun_udp.py:21` — ответ на любую датаграмму без лимитов; рефлекторная амплификация.
- **M-16** App: публичные комнаты без шифрования при privacy-first позиционировании (`room_service.dart:95`); ключ вложения в метаданных (`:1754`); логгер экспортирует полный текст (`app_logger.dart`).
- **M-17** App: `stun.l.google.com` по умолчанию (деанонимизация по IP), нет пиннинга сертификата, `Random()` в mesh/аудио-путях.

---

## 5. LOW / INFO (сжато)

`_test_token` из URL в `localStorage` (legacy, FE-04) · `javascript:`-схема в `href` превью ссылок · числовые поля банка без `Number()` · seed-фраза остаётся в DOM (`index.html:2638`) · `_meta_hash` 6-значных кодов · отсутствие `allowBackup="false"`/`dataExtractionRules` в манифесте · 20 exported `activity-alias` и label «GhostChat Test» · exported `AudioService`/`MediaButtonReceiver` · `REQUEST_INSTALL_PACKAGES` без ужесточения целостности · IV/seed: всё в порядке (см. §7) · `shop` open redirect через `next` · `backchat/main_remote.py.save*` в git · `desktop-commander-agent.service`, `.codex-backups`, `.claude` в рабочей копии.

---

## 6. Что подтвердилось / что опровергнуто

**Опровергнуто живьём (не воспроизводится):**
- «Бэкапы `app.js.bak_*`, `auth.js.bak.*` отдаются как статика» → **404**. Конфиг закрывает; замечание остаётся гигиеническим (файлы лежат в web-root).
- «Секреты в юнитах читает любой юзер» → `ghostchat/ghostsocial/ghostnation.service` **600**. Реальная часть проблемы — drop-in'ы, `.env`-каталоги и общий `GC_JWT_SECRET`.
- «`/media/` отдаёт листинг» → **403**.
- «`/api/soc/admin/*` открыт» → **401** без токена.

**Требует проверки на стенде (не подтверждено):**
1. Значение `users.tda_enabled` по умолчанию и миграция — от него зависит реальная тяжесть C-1.
2. Оставлен ли legacy `chat/index.html` в артефактах деплоя (сейчас не отдаётся).
3. Проверяет ли клиент подпись ассет-манифеста OTA (иначе H-33 → critical).
4. `device_name`-санитация на сервере (от неё зависит эксплуатация FE-02).
5. `flutter_secure_storage` опции в реальном APK (`encryptedSharedPreferences`) — влияет на C-4.
6. `any`-проверка `callback_data` в `bot_api.py:1869` — нужна ли привязка к user_id на стороне бота.
7. `grep`-проход по `ghogem/ai.py` (579 КБ) на обработку tool-результатов.

---

## 7. Что сделано хорошо (не переделывать)

- **Крипто ядра:** Argon2id `t=2, m=64MiB, p=2`, SRP-подобный вход с одноразовым challenge под `BEGIN IMMEDIATE`, `compare_digest` везде, параметры KDF жёстко ограничены диапазонами (нельзя продавить слабый KDF).
- **E2E:** сервер не хранит и не расшифровывает приватный ключ; `key_security` проверяет формат/длины контейнера; v2 — X25519 + HKDF-SHA256 + AES-GCM с `newNonce()`; TOFU с отказом при смене; `vault.ts` — `CryptoKey extractable=false`.
- **Сессии:** device-bound JWT с `jti` + `revoked_tokens` + `token_min_iat`; отзыв устройства учитывается и в HTTP, и в WS.
- **SSO:** PKCE S256 обязателен, `redirect_uri` строго из allowlist, `state` ≥16, код одноразовый, `Cache-Control: no-store`; service-to-service — HMAC с nonce и skew 60 с.
- **Экономика:** все денежные операции под `BEGIN IMMEDIATE` с `ROLLBACK`; суммы в диапазонах, комиссии в bps; self-transfer и покупка своего листинга запрещены; IDOR закрыт на list/unlist/transfer/invoice/username/mint.
- **SQL:** нет ни одной инъекции — только `?`-плейсхолдеры, `ORDER BY` из whitelist.
- **Загрузки:** имена на диске — `uuid4`, клиентское имя не используется; аватар перекодируется PIL; отдача чат-файлов `application/octet-stream` + `no-store`.
- **Комнаты:** инвайты — `token_urlsafe(32)`, в БД `sha256`; права проверяются и до, и после транзакции; чтение скоупится по `receiver_user_id/device_id`.
- **Приложение:** ключи в Keystore, `usesCleartextTraffic=false`, нет `badCertificateCallback`, FCM без контента, экспорт БД шифрован Argon2id+AES-GCM, VPN-плагин ограничен своим package.
- **Инфраструктура:** порты только loopback, `ProtectSystem=strict`/`ProtectHome`/`NoNewPrivileges`, `server_tokens off`, `log_format` без query, `/ws` и `/api/soc/ws` без access-log и с очисткой query, APK → 410, `/docs|redoc|openapi` → 403, SSH hardening.

---

## 8. План исправлений по приоритету

**Сегодня (C-level, каждый — часы):**
1. C-1 — закрыть legacy-вход, требовать TDA для любого нового устройства.
2. C-2 — WS `keys.upload` → `validate_key_upload`, удалить дубли обработчиков.
3. C-5 — admin-токен только из заголовка; развести control/economy; ротировать `GE_ADMIN_TOKEN`.
4. C-6 — убрать дефолтный `_SUPPORT_PASSWORD`, `compare_digest`, ротировать.
5. C-4 — убрать fallback токена в `SharedPreferences`, включить SQLCipher.

**На этой неделе (H):**
6. H-1/H-3 — CAS для одноразовости логина, хэш+TTL для токенов в БД.
7. H-7/H-8/H-9 — `keysync` owner-проверка + лимиты; `device_id` только серверный; лимит кадра WS.
8. H-12/H-13/H-14 — SSRF по IP-пиннингу, `UPDATE … WHERE balance>=?`, cap на mint.
9. H-16/H-17/H-18/H-19 — `textContent` вместо `innerHTML`, CSP + локальные копии CDN, HttpOnly-cookie для v2, `CryptoKey` вместо сырого seed.
10. H-20…H-23 — `FLAG_SECURE`, sens-буфер, проверка SHA-256/`versionCode` APK, auth кадром WS.
11. H-24/H-27/H-29/H-31/H-33 — `EnvironmentFile` 600 + развести `GC_JWT_SECRET`, `ssl_ciphers`+stapling, `forwarded_allow_ips=127.0.0.1` + лимит на `/shop/api/login`, отдельный keyspace для rate-limit, TTL+одноразовость OTA-токена.

**Следующий спринт (M):** приватность жалоб и OG-кэша, атомарность overwatch/инвайтов, аудит-лог эмиссии, `plain_text` поддержки, лимиты STUN, allow-list инструментов GhoGem, DNS/STUN-приватность в приложении.

**Гигиена:** убрать `*.bak*` из web-root и деплой-артефактов, `main_remote.py.save*` из git, `.codex-backups`/`.claude` из рабочей копии, единый источник `social_router.py` (две копии уже разошлись на 239 строк), CI-проверка расхождения `server/chat` ↔ `server/ghostecos-core`.

---

## 9. Приложение: где что лежит

| Компонент | Путь |
|---|---|
| Ядро API | `server/ghostecos-core/**` (прод: `/opt/ghostchat`, порт 8002) |
| Соцсеть/экономика | `server/ghostecos-core/social_router.py` (9520 стр.), дубль `server/social/social_router.py` |
| Чат | `chat_router.py`, `chat_router_v2.py`, `room_router_v2.py`, `channel_router_v2.py`, `chat_client_bridge.py` |
| Боты/OTA | `bot_api.py`, `bot_runner_*`, `code_ota.py`, `app_config_ota.py` |
| v2-фронт чата | `server/chat/web/src/**` (Svelte 5) → `/var/www/ghostchat/v2` |
| Legacy-чат | `server/chat/index.html` (не отдаётся: `/v1/chat` → 410) |
| Соцсеть/банк/лендинг | `server/social/frontend/static/**`, `server/bank/index.html`, `server/site/**`, `server/ghostauth/auth.js` |
| Приложение 1.2.2 | `app/ghostchat/lib/**` (195 файлов), `android/app/src/main/AndroidManifest.xml` |
| Инфра | `server/nginx/*.conf`, `server/deploy/*.service`, Go: `server/ghostsound/**`, `server/ghosou/**`, `server/nation/server.py` |
