# GhostChat v1 — места где ломаются ключи

Документ-аудит того что я видел за сессию + потенциальные места. Ссылки
на код — `/var/www/chat/index.html` (он же `server/chat/index.html`).

## ⚠ Подтверждённые баги (поломались в живой эксплуатации)

### 1. IDB priv vs server pub mismatch
**Когда:** юзер переключал storage_mode или восстанавливал из бэкапа.
**Симптом:** waki — стена «не удалось расшифровать», потому что priv в IDB
не соответствует pub на сервере, AEAD рейджектит.
**Чем покрыто:** `_checkLocalPubMatchesServer` (init-path + _ensureKeysLocal).
В _ensureKeysServer проверка была изначально (`if (myPub && remote.x25519_pub
&& remote.x25519_pub !== myPub) wipeKeysIDB`).

### 2. user_devices.pub_key очищается при restore из бэкапа
**Когда:** мой ручной restore waki из бэкапа 11 июня.
**Симптом:** /keys/{username}.device_pubkeys пустой, multi-device fanout
ломается (но и так не используется в v1 send).

## Потенциальные места (не наблюдал, но могут быть)

### 3. `wipeKeysIDB` чистит только store `keys`, НЕ `peerkeys`
`wipeKeysIDB()` clear-ит `keys`. `peerkeys` (TOFU pin'ы чужих pub'ов) живут.
**Риск:** если собеседник сменил pub, у меня в peerkeys всё ещё старый pin.
**Покрыто:** verifyAndPinPub срабатывает в decryptFromPeer при mismatch.
Но это после первой fail-decrypt — одно сообщение уже сломано.

### 4. `pubCache` (in-memory Map) не инвалидируется
`encryptForPeer` фетчит pub собеседника, кладёт в `pubCache.set(peer, pub)`.
Если в той же сессии собеседник сменил ключ — мой клиент шифрует под
старый pub до перезагрузки страницы.
**Митигация:** перезагрузка инвалидирует Map. На long-lived sessions —
дыра.

### 5. `saveKeysToIDB` пишет priv и pub двумя транзакциями
`saveKeysToIDB(pkcs8Bytes)` делает два `put` в одной tx — это атомарно.
**ОК**, ничего не делать.

### 6. При смене пароля через `/api/soc/me PATCH new_password`
`social_router.py:2633` зануляет `encrypted_private_key` и `key_salt`.
**Риск:** Других устройств юзера это не предупреждает — они при следующем
`/keys/me` получат NULL и упадут в «генерируем новый» путь, который
перепишет `x25519_pub` собеседникам в users. Все старые сообщения от
этого юзера во всём чате потеряют возможность расшифроваться.

### 7. `verifyAndPinPub` срабатывает асинхронно при decrypt fail
**Гонка:** сообщение помечается «[не удалось расшифровать]» в IDB
до того как юзер успел подтвердить новый ключ через TOFU. Расшифровка
не пересчитывается — текст «[не удалось расшифровать]» остаётся в
истории навсегда.

### 8. Multi-device sender fanout НЕ реализован в v1 send
`/api/chat/send` шифрует один envelope под `x25519_pub` (owner). Не
итерирует `device_pubkeys`. Не-owner устройства не могут расшифровать
incoming если они зарегистрированы как multi-device.
**Покрытие:** /keys/upload не-owner устройства не переписывает
`users.x25519_pub` (chat_router.py:103-109). То есть фактически
multi-device в v1 не работает.

### 9. `channel_keys.wrapped_key` зашифрован под старый pub
Когда юзер генерит новый identity pub (rotate / wrong password fallback /
restore из бэкапа), все его `channel_keys.wrapped_key` записи становятся
нерасшифровываемы. **Нет** механизма re-wrap. Юзеру нужно либо вручную
заново «добавить себя» в каждый канал, либо принять что каналы умерли.

### 10. Race condition при первом запуске
`doLogin` → `ensureKeys` → `_ensureKeysServer` → IDB пуст → decrypt.
Параллельно WebSocket уже мог доставить `chat.new`. `ingestIncoming`
сразу пытается decrypt → `myPriv` ещё null → новый код кидает понятную
ошибку, но сообщение в БД ack'ается? Нужно проверить.

### 11. `_ensureKeysServer` при wrong password
Кидает `Error('Неверный пароль для расшифровки ключей')`. Состояние
`myPriv`/`myPub` к этому моменту уже могло частично установиться?
Нужно гарантированно reset в catch.

### 12. Если юзер сменил mode `server→local` и не закрыл другие устройства
Сценарий: устройство 1 переключает в `local`. Устройство 2 в фоне
получает изменения — `/keys/me` теперь возвращает `null` для
`encrypted_private_key`. Если оно на онлайн-сессии — priv в IDB ещё
работает. При reload — у него `mode=local`, IDB priv валидный (тот же),
но push с сервера ему уже не помогут восстановиться если IDB будет
вытерт.

## Что сделано как защита

- `_checkLocalPubMatchesServer` — wipe + banner при mismatch.
- `myPriv=null` → понятная ошибка вместо AbortError в encrypt/decrypt.
- KeyMissing banner с тремя путями (QR / Файл / Сервер).
- TOFU `verifyAndPinPub` уже существовал.
- Safety code (только что добавил) — юзер сам сверяет.
- Rotate key (только что добавил) — управляемая смена.

## Что НЕ покрыто в v1 и переезжает в v2 (KEYS_V2_SPEC.md)

- Forward Secrecy (отдельный ключ на каждое сообщение).
- Multi-device fanout (Ed25519 identity + signed_prekey per device).
- TOFU замена → cryptographic verification через identity signature.
- Recovery через seed-фразу.
- Sealed sender / receiver (метаданные).
