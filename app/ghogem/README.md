# GhostGem — нативное приложение (Desktop + Android)

> Чат + агент на той же логике что и Telegram-бот и веб-версия `server/ghogem/web_api.py`. Режим **Сервер** (общие ключи, лимиты) и **BYOK** (свои ключи на устройстве, безлимитно).

**Путь:** `C:\Users\Home\GE\app\ghogem`  
**Билд Windows:** `build\windows\x64\runner\Debug\ghogem.exe` (уже собран)  
**Тема:** Noir v2 (`ghostecos-v2-noir.html`) — #0a0710 / #efe9f5 / #7c3aed

## Запуск

```bash
cd C:\Users\Home\GE\app\ghogem
flutter pub get

# Desktop (Windows уже собирается без ATL — secure_storage заменён на base64 в SharedPrefs)
flutter run -d windows
# или
.\build\windows\x64\runner\Debug\ghogem.exe

# Android (требует Android SDK/NDK 36)
flutter run -d android
flutter build apk --debug
flutter build apk --release
```

## Архитектура

```
Flutter (ghostgem)
 ├─ Сервер-режим ──> https://ghostecos.duckdns.org/ghogem-api
 │                     ├─ GET /models  (каталог 80+ моделей)
 │                     ├─ WS  /ws/chat (стриминг токенов + thinking + tools)
 │                     ├─ GET /chats, /chats/history, /files
 │                     └─ identity: guest (без токена) | gs_token (привязка GhostEcos)
 │
 └─ BYOK-режим ──> прямой OpenAI-совместимый вызов с устройства
                    ├─ Groq, Mistral, OpenRouter, SambaNova, BazaarLink, Zveno, Vireonix, PersorAI, Free.ai; Work tools используют Pollinations через серверный SOCKS proxy
                    ├─ ключ хранится на устройстве (SharedPrefs base64 MVP, на Android вернём SecureStorage)
                    └─ история локально sqflite
```

**Гибрид:** переключатель в шапке — `Сервер` vs `BYOK`. Текущая модель сохраняется отдельно для каждого режима (`gg_server_model` / `gg_byok_model` в `SharedPreferences`).

## Что внутри (MVP v1)

- **Чаты:** `lib/services/chat_store.dart` — sqflite `ghogem.db` (таблицы `chats`/`messages`), автозаголовок из первого сообщения, свайп-меню переименовать/удалить.
- **Модели:** `lib/screens/models_screen.dart` — провайдер-табы (Groq/Mistral/OpenRouter…), поиск, бейджи premium/параметры/creator, выбор сохраняет в настройки + (в сервер-режиме) `POST /models/select`.
- **Ключи:** `lib/screens/keys_screen.dart` — 7 провайдеров с ключами, скрытый ввод и `Сохранить`/`Проверить`; Pollinations всегда идёт через серверный ключ и SOCKS-прокси, Vireonix, CVRON, VisionSter и PersorAI работают без пользовательского ключа.
- **Чат:** `lib/screens/home_screen.dart` — адаптивный layout (280px sidebar на ≥860px, drawer на телефоне), маркдаун + thinking-блок + стрим `▌`, подсказки, аттач (заглушка file_selector).
- **Тема:** `lib/theme.dart` — `GG` (скопирован noir v2), glass blur 18, жидкий фон + скругление.
- **Сервер-стрим:** `lib/services/api_service.dart` — `WebSocketChannel` к `wss://ghostecos.duckdns.org/ghogem-api/ws/chat`, протокол как у `web_api.py:ws_chat`.
- **BYOK-стрим:** `lib/services/byok_service.dart` — SSE `data:` → `choices[0].delta.content`, с `params_b` каталогом для правильного `model` id.

## Веб уже есть

Веб-версия GhoGem живёт на `https://ghostecos.duckdns.org/ghogem` и уже проксирует `/ghogem-api` → `127.0.0.1:8021` (`server/ghogem/web_api.py`). Новое приложение переиспользует те же эндпоинты — бэкенд дописывать не нужно, только если захочешь отдельный HTTP non-WS fallback.

## Следующие шаги (M2)

1. **Настоящий SecureStorage на Android:** вернуть `flutter_secure_storage` + `biometric_storage` (на Windows оставить SharedPrefs — ATL требует VS ATL).
2. **Файлы агента:** `file_selector` → `POST /files/upload`, `files/content`, превью image/video/audio, отправка файлов вместе с промптом (multimodal).
3. **Напоминания/память:** экраны для `GET /reminders` + `read_memory/write_memory` tools, карточка напоминания.
4. **Пуш/FCM для десктопа:** `flutter_local_notifications` + WebSocket reconnect.
5. **Встраивание в GhostChat:** добавить 5-й таб `GhoGem` в `GE/app/ghostchat/lib/screens/main_shell.dart` → `Section.ghogem` (реюз `GG` темы и `AuthService` токена).

## Отличия от `C:\ghogem`

`C:\ghogem` — старый срез бота (до 06.10). Актуальный бот — `C:\Users\Home\GE\server\ghogem` (80+ моделей, agent loop, tool_registry, media quotas). Приложение смотрит на актуальный.

## Лицензия

AGPL-v3 — как весь GhostEcos.
