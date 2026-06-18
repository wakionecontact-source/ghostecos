# GhostChat Keys v2 — спецификация

Полная переработка криптосистемы GhostChat. Цель: устранить проблемы v1
(сменил режим → потерял ключ → история мёртвая) и поднять защиту до уровня
Signal/WhatsApp.

## TL;DR — что меняется

| Что | v1 (было) | v2 (будет) |
|---|---|---|
| Identity | x25519_pub в users | Ed25519 identity_pub (никогда не меняется) |
| Recovery | пароль + ключ на сервере | seed-фраза 12 слов + ещё 3 пути |
| Forward Secrecy | нет | да (Double Ratchet, новый ключ на каждое сообщение) |
| Multi-device | один ключ на все устройства | каждое устройство свой keypair |
| TDA | подтверждение + token | подтверждение + token + identity_priv (готов к работе сразу) |
| Старая переписка | теряется при смене режима | живёт под v1, не трогается |

## Recovery: 4 пути

Юзер при регистрации видит фразу из 12 английских слов (BIP-39 стандарт)
и **обязательно** должен подтвердить что записал — снять галочку «я
сохранил» нельзя без этого шага.

После этого ключ восстанавливается любым из:

1. **Seed-фраза** — на любом устройстве, без сети, без сервера. Самый
   надёжный путь. Юзер вводит 12 слов → identity_priv обратно.
2. **Пароль аккаунта** — identity_priv хранится зашифрованным паролем на
   сервере (опционально, юзер выбирает). При логине паролем сразу
   расшифровывается. Удобно, но компромисс.
3. **Файл `.gcsk`** — зашифрованный паролем файл с identity_priv. Удобно
   для резервной копии в облако.
4. **TDA-передача** — при approve нового устройства с уже доверенного
   через 6-значный код, trusted устройство автоматически передаёт
   identity_priv по защищённому каналу (ECDH с сервером как proxy, как
   в текущем QR-sync). Самый удобный путь когда есть второе устройство.

## Криптостек

### Identity layer (один на юзера)

- **Ed25519** keypair: `identity_priv`, `identity_pub`.
- Из seed-фразы: PBKDF2-HMAC-SHA512(mnemonic, "ghostchat-v2", 2048 iter)
  → 64 байта seed → HKDF-SHA256 → 32 байта identity priv seed →
  Ed25519 keypair.
- identity_pub — публичный «адрес» юзера на сервере, не меняется.

### Device layer (свой на каждое устройство)

- **X25519** ECDH keypair: `device_priv`, `device_pub`.
- Каждое устройство при первом запуске генерит свою пару.
- Signed PreKey = ( device_pub, Ed25519_sign(identity_priv, device_pub) ).
- На сервере: `user_devices` хранит signed_prekey каждого устройства.
- Подпись проверяется при получении pubkey собеседника — гарантирует, что
  device_pub реально от того юзера, кем подписан identity_priv.

### Session layer (per-conversation)

**X3DH handshake** при первом сообщении в пару:
- Sender генерит ephemeral X25519 пару.
- Считает три ECDH: (eph, recipient_signed_prekey), (identity, recipient_signed_prekey),
  (eph, recipient_identity_pub). Объединяет HKDF → root key.
- Шлёт первое сообщение с eph_pub в envelope.

**Double Ratchet** для всех последующих:
- **Symmetric ratchet**: каждое сообщение HKDF продвигает chain key →
  message key. Прошлые сообщения остаются неоткрываемыми.
- **DH ratchet**: при каждом ответе генерится новая DH пара, обмен
  даёт новый root key. Раскрытие текущего state не даёт читать
  будущие сообщения.

### Symmetric layer

- HKDF-SHA-256 везде где derive.
- AES-256-GCM AEAD для сообщений. AD = identity_pub отправителя + receiver_pub + ratchet index.

## Формат сообщения v2

```
envelope = {
  v: 2,                       // версия
  from_id: "ed25519_pub_b64", // identity_pub отправителя
  ratchet_idx: int,           // позиция в ratchet
  dh_pub: "b64",              // текущий DH ratchet pub
  prev_chain_n: int,          // длина прошлой chain (для late delivery)
  iv: "b64",                  // 12 байт
  ct: "b64"                   // AES-GCM(message_key, plaintext, AD)
}
```

`plaintext` внутри — JSON `{type, text, ...}` как сейчас.

## Эндпойнты v2

Префикс: `/api/chat/v2/`

- `POST /v2/register_identity` — после регистрации опубликовать identity_pub.
  Body: `{identity_pub, identity_signature_test}` (challenge: подписать "ghostchat-v2-claim").
- `POST /v2/device/publish` — опубликовать device signed_prekey.
  Body: `{device_pub, identity_sig_of_device_pub}`.
- `GET /v2/keys/{username}` — получить identity_pub + список signed_prekey
  всех его активных устройств.
- `POST /v2/send` — отправить v2 envelope. Body: `{to_user_id, device_targets: [...envelopes]}`.
- `GET /v2/pending` — забрать pending v2 сообщений.
- `POST /v2/ack` — подтвердить доставку.

TDA-передача:
- `POST /v2/devices/pending/{rid}/approve` — payload включает зашифрованный
  identity_priv под shared secret из ECDH между trusted device_pub и нового
  устройства pre-published device_pub.

## Хранение на клиенте (IDB)

```
ghostchat-{user}/
  identity (один объект):
    identity_priv: pkcs8 raw
    identity_pub:  raw
    seed_mnemonic_hash: hash (для подтверждения seed без хранения)
  device (один объект):
    device_priv: pkcs8
    device_pub:  raw
  sessions (по одному на peer):
    peer_id (Ed25519 pub b64): {
      root_key, send_chain, recv_chain,
      send_n, recv_n, prev_send_n,
      pending_skipped_keys: [...],  // для out-of-order delivery
      dh_pair, peer_dh_pub
    }
  messages (как в v1, plaintext history)
```

## Миграция

- v1 остаётся читать-только. Старые сообщения в IDB видны.
- При первом входе после деплоя v2:
  - юзер видит модалку «Обновление безопасности GhostChat».
  - предлагается: либо ввести seed (если бэкап есть), либо сгенерить новую
    identity. Старый ключ переезжает в "Архив".
  - все собеседники получат уведомление "у X сменился identity_pub,
    подтвердите".
- Отправка сообщений собеседникам, ещё не перешедшим на v2 — fallback
  на v1 транспорт с предупреждением «у собеседника старая версия».

## Что НЕ делаем сейчас

- Sealed receiver (метка «кому» открыта серверу) — отдельная фаза.
- Group чаты с Forward Secrecy (Sender Keys из Signal) — отдельно.
- Pre-key bundle на 100 одноразовых ключей — пока хватит один signed_prekey
  на устройство, замена при экспирации.

## План имплементации

1. **Этап 1 (бэкенд)**: миграция БД, v2 эндпойнты, регистрация identity,
   публикация device prekey.
2. **Этап 2 (JS клиент)**: BIP-39 wordlist, генерация identity из seed,
   модалка показа seed, device key. X3DH + Double Ratchet. Send/receive.
3. **Этап 3 (TDA-передача)**: расширение pending_logins для передачи
   зашифрованного identity_priv.
4. **Этап 4 (Python клиент)**: имплементация для @claude_helper, чтобы
   я мог продолжать общаться.
5. **Этап 5 (UI)**: настройки → seed-фраза, экспорт, импорт. Тестирование
   recovery.
