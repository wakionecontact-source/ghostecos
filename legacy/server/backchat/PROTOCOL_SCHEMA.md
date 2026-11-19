# GhostChat Server — Полная схема протокола

## HTTP Endpoints

### Аутентификация

```
POST /api/register
  client → { username, display_name, password, x25519_pub, ed25519_pub }
         ← { ok, user_id }

POST /api/login
  client → { username, password, device_id, device_name }
         ← { token, user_id, status:"ok" }          — известное устройство
         ← { status:"pending", request_id, user_id } — новое устройство
```

### Вход с нового устройства (Device Trust Flow)

```
 Новое устройство (D2)          Сервер              Старое устройство (D1, online)
        │                          │                          │
        │  POST /api/login         │                          │
        │ ─────────────────────►  │                          │
        │  ← { pending, req_id }  │  WS: login_request ──►  │
        │                          │                          │
        │  GET /api/login_request/{id}  (polling 2s)         │
        │ ─────────────────────►  │                          │
        │  ← { status:"pending" } │                          │
        │                          │                          │
        │                          │  ◄── WS: login_approve  │  (D1 нажал "Да")
        │                          │                          │
        │  GET /api/login_request/{id}                        │
        │ ─────────────────────►  │                          │
        │  ← { status:"code_phase"}│  WS: code_ready_notify ►│
        │                          │                          │
        │  POST /api/login_request/{id}/code_ready            │
        │ ─────────────────────►  │                          │
        │  ← { ok }               │                          │
        │                          │                          │
        │                          │  ◄── WS: login_submit_code  (D1 ввёл код)
        │                          │                          │
        │  GET /api/login_request/{id}                        │
        │ ─────────────────────►  │                          │
        │  ← { status:"verify_phase", submitted_code }        │
        │                          │                          │
        │  POST /api/login_request/{id}/code_verify           │
        │ ─────────────────────►  │                          │
        │  ← { result:"success" } │  WS: login_confirmed ──► │
        │                          │                          │
        │  GET /api/login_request/{id}                        │
        │ ─────────────────────►  │                          │
        │  ← { status:"ok", token }│                         │
```

```
GET  /api/login_request/{id}           — D2 polling
POST /api/login_request/{id}/code_ready  — D2 сообщает что код готов
POST /api/login_request/{id}/code_verify — D2 сообщает совпал ли код
GET  /api/my_pending_logins            — D1 получает список запросов (polling)
```

### Профиль / Пользователи

```
GET  /api/user/{username}    → { username, display_name, about, x25519_pub, ed25519_pub }
POST /api/profile            → { display_name?, about?, x25519_pub?, ed25519_pub?, avatar? }
```

### Контакты

```
POST /api/contacts           → { username }  — добавить контакт
GET  /api/contacts           → { contacts: [...] }
```

### Файлы

```
POST /api/files/upload
  client → multipart: file + JSON metadata (to_username, file_id, enc_key_for_recipient, ...)
         ← { file_id, ok }
  server → WS: file_incoming → получателю (если онлайн)
  иначе  → pending, доставляется в фоне (каждые 30s)

GET  /api/files/{file_id}       — скачать файл (Bearer token)
POST /api/files/{file_id}/ack   — подтвердить получение
POST /api/files/{file_id}/reupload — повторно загрузить (по запросу сервера)
```

### Каналы (групповые чаты)

```
POST /api/channels                         — создать канал
GET  /api/channels                         — все каналы
GET  /api/channels/my                      — мои каналы
GET  /api/channels/{id}                    — инфо канала
POST /api/channels/{id}/join               — вступить (или создать join_request)
GET  /api/channels/{id}/join_requests      — список заявок (только admin)
POST /api/channels/{id}/approve/{username} — одобрить заявку
POST /api/channels/{id}/reject/{username}  — отклонить заявку
POST /api/channels/{id}/key               — загрузить enc_key для члена
GET  /api/channels/{id}/key               — получить enc_key
DELETE /api/channels/{id}/messages/{msg_id} — удалить сообщение
POST /api/channels/{id}/leave             — покинуть канал
DELETE /api/channels/{id}                 — удалить канал (только создатель)
GET  /api/channels/{id}/messages          — история (pagination)
GET  /api/channels/{id}/members           — список участников
```

### Поддержка

```
GET /api/support/messages   — история чата поддержки (auth required)
```

### Синхронизация сообщений

```
POST /api/messages/sync
  client → { msg_ids: [...] }
         ← { statuses: { msg_id: { delivered, seen } } }
```

### Устройства (Device Trust)

```
GET    /api/devices                        → { devices: [...] }
POST   /api/devices/{device_id}/trust      → { trust_type, trust_level }
POST   /api/devices/{device_id}/permissions → { permissions: {...} }
DELETE /api/devices/{device_id}            — заблокировать устройство
```

---

## WebSocket /ws

### Подключение

```
client → { type:"auth", token:"JWT", device_id:"..." }
server ← { type:"auth_ok" }
       ← { type:"auth_fail", reason:"..." }
```

### Startup sync (сразу после auth_ok)

```
server → { type:"peer_online", username }          — для каждого онлайн-контакта
server → { type:"relay_message", ... }             — оффлайн сообщения
server → { type:"sync_summary", total, senders }   — сводка
server → { type:"device_trust", trust_type, trust_level, permissions }
server → { type:"support_history", messages:[...] }
server → { type:"pending_logins_sync", requests:[...] }
```

### Keepalive

```
client → { type:"ping" }
server ← { type:"pong" }
server → { type:"pong" }   — keepalive если 60s нет входящих
```

### Сообщения (P2P через сервер)

```
client → { type:"relay_message", to_username, enc_body, msg_id, sent_at,
           forwarded_from?, reply_to_msg_id? }
server ← { type:"relay_ack", msg_id }               — подтверждение от сервера
target ← { type:"relay_message", from_username, enc_body, msg_id, sent_at, ... }

client → { type:"relay_seen", msg_ids:[...] }
target ← { type:"relay_seen", msg_ids:[...] }

client → { type:"relay_delete", msg_id }
target ← { type:"relay_delete", msg_id }

client → { type:"relay_edit", msg_id, enc_body }
target ← { type:"relay_edit", msg_id, enc_body }

client → { type:"relay_screen_lock", to_username }
target ← { type:"relay_screen_lock", from_username }
```

### Статус онлайн

```
server → { type:"peer_online",  username }
server → { type:"peer_offline", username }

client → { type:"set_background", value:true/false }
         — при true: сервер шлёт peer_offline контактам
         — при false: шлёт peer_online + доставляет оффлайн-сообщения

client → { type:"peer_status_req", username }
server ← { type:"peer_online/peer_offline", username }
```

### Каналы (WS)

```
client → { type:"channel_message", channel_id, enc_body, msg_id, sent_at }
members ← { type:"channel_message", channel_id, from_username, enc_body, msg_id, sent_at }

server → { type:"join_request", channel_id, username }   — admin уведомление
server → { type:"join_approved", channel_id }
server → { type:"join_rejected", channel_id }
server → { type:"channel_message_deleted", channel_id, msg_id }
server → { type:"kicked", channel_id }
```

### Файлы (WS)

```
server → { type:"file_incoming", file_id, from_username, filename,
           enc_key, file_size, mime_type, sent_at }
server → { type:"file_reupload_request", file_id, request_id,
           original_filename, to_username, enc_key_for_recipient }
```

### Device Trust (WS)

```
server → { type:"login_request", request_id, device_id, device_name, client_ip }
server → { type:"code_ready_notify", request_id, attempts_left }
server → { type:"login_confirmed", request_id }
server → { type:"login_denied_notify", request_id }
server → { type:"code_wrong_notify", request_id, attempts_left }

client → { type:"login_approve", request_id }
server ← { type:"login_approve_ack", request_id }

client → { type:"login_deny", request_id }
server ← { type:"login_deny_ack", request_id }

client → { type:"login_block", request_id }
server ← { type:"login_block_ack", request_id }

client → { type:"login_submit_code", request_id, code }
server ← { type:"code_submit_ack", request_id }
```

### Поддержка (WS)

```
server → { type:"support_incoming", msg_id, from_username, body, sent_at }
server → { type:"support_reply",    msg_id, body, sent_at }
client → { type:"support_message",  body }
```

### App lifecycle

```
client → { type:"app_ready" }
server ← { type:"app_ready_ack" }

client → { type:"sync_request" }   — вручную запросить оффлайн-сообщения
```

### Контакты (WS)

```
server → { type:"contact_added", username, display_name, x25519_pub, ed25519_pub }
```

---

## Что надо переписать / улучшить

- [ ] Всё через WS вместо HTTP polling (login_request, my_pending_logins)
- [ ] Единый формат пакетов: { type, id, payload }
- [ ] Нормальная авторизация WS (не JWT в первом пакете)
- [ ] Отдельные роутеры FastAPI по модулям (auth, contacts, channels, files, devices)
- [ ] rate limiting по токену, не только по IP
- [ ] Heartbeat двусторонний (сейчас только ping→pong)
