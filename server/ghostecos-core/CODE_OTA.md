# GhostChat OTA: текущая реализация

OTA разбита на два независимых слоя. Dart-патчи временно подготовлены на основе
GhostEcos-форка Shorebird CLI/updater, но **выключены по умолчанию**: серверный
entrypoint не публикует их API, а `auto_update` в `shorebird.yaml` установлен в
`false`. Исходники и тесты сохранены. Повторное включение серверных Dart-маршрутов
возможно только явным `GC_DART_CODE_OTA_ENABLED=1`; assets при этом остаются
доступны. Для Dart-патчей всё равно нужен APK со специально собранным Flutter
engine. Assets обслуживает отдельный GhostEcos-протокол: подписанный
RSA-манифест, SHA-256 каждого файла и локальный overlay в приложении.
Установка/выкладка на сервер в рамках этой работы не выполнялась.

## Настройка сервера

- `GC_CODE_OTA_ADMIN_TOKEN` — bearer-секрет для CLI и публикации assets;
- `GC_DART_CODE_OTA_ENABLED` — включает серверные Dart Code OTA маршруты только
  при значении `1`, `true`, `yes` или `on`; по умолчанию выключено;
- `GC_CODE_OTA_PUBLIC_URL` — внешний HTTPS origin, по умолчанию
  `https://ghostecos.duckdns.org`;
- `GC_CODE_OTA_DIR` — каталог SQLite и бинарных файлов, по умолчанию
  `/opt/ghostchat/code_ota`;
- `GC_CODE_OTA_DB_PATH` — необязательный отдельный путь к SQLite;
- `GC_CODE_OTA_MAX_ARTIFACT_BYTES` — предел файла, максимум 2 GiB; для Nginx
  upload-маршрута сейчас задан лимит 260 MiB;
- `GC_CODE_OTA_REQUIRE_SIGNATURE` — подпись Dart-патча обязательна, если явно
  не задано `0`;
- `GC_CODE_OTA_ASSET_PRIVATE_KEY` — путь к PEM RSA private key для подписи
  манифестов assets. Приватный ключ нельзя хранить в репозитории или APK.

В production нужно настроить те же RSA-ключи, что соответствуют
`patch_public_key` в `app/ghostchat/shorebird.yaml`. Серверу также нужна уже
используемая GhostEcos зависимость Python `cryptography`.

## Публикация assets

Сначала собери APK локально, чтобы Flutter подготовил `build/flutter_assets`,
затем запусти на машине публикации из каталога `server/ghostecos-core`:

```powershell
$env:GC_CODE_OTA_ADMIN_TOKEN = "<секрет публикации>"
python .\publish_asset_ota.py `
  --assets-dir ..\..\app\ghostchat\build\flutter_assets `
  --version 1.2.2+4120-assets-1
```

Скрипт регистрирует набор файлов, загружает их, затем активирует релиз. Если
загрузка оборвалась, повторный запуск с той же версией и теми же файлами
возобновит незавершённую публикацию. Изменённые файлы под тем же номером
отклоняются. После активации приложение проверяет релиз при запуске, сверяет
уже установленные SHA-256 с сервером, скачивает только недостающие данные,
проверяет RSA-подпись манифеста и хэши, сохраняет файлы локально и обновляет
Flutter `DefaultAssetBundle`; после успешной активации неиспользуемые blobs
очищаются. Данные настроек/кэша приложения этим не
перезаписываются.

Первый активированный asset-релиз должен соответствовать установленной базе
APK. Публиковать набор только из новых или изменённых файлов нельзя: манифест
описывает полный активный набор, а отсутствующие в нём пути удаляются из
overlay.

## Toolchain CLI

`publish_toolchain_ota.py` публикует готовые архивы updater'а по ревизии
движка. Допустимые имена: `aot-tools.dill`, `patch-darwin-arm64.zip`,
`patch-darwin-x64.zip`, `patch-linux-x64.zip`, `patch-windows-x64.zip`.

```powershell
python .\publish_toolchain_ota.py `
  --engine-revision <точная-ревизия-engine> `
  --artifact patch-windows-x64.zip=C:\build\patch-windows-x64.zip `
  --artifact aot-tools.dill=C:\build\aot-tools.dill
```

CLI обращается только к GhostEcos для updater-артефактов; если нужной ревизии
там нет, команда завершится ошибкой, не переключаясь на Shorebird. Сам движок и
нативные плагины всё равно поставляются APK. Отдельный Maven путь для Android
не нужен — релиз собирается как APK.

## Границы текущего asset overlay

Приложение подменяет данные, запрошенные через Flutter `DefaultAssetBundle`;
явное чтение BIP-39 wordlist и UI-звуки также направлены через него. Шрифты,
шейдеры и ресурсы, загружаемые нативными плагинами напрямую из APK/AssetManager,
этим Dart-слоем не подменяются. Для полного охвата таких ресурсов потребуется
native hook в пересобранном Flutter engine/APK. Недоверенный исполняемый код,
JavaScript и Dart-манифесты сервер не принимает.

Серверный production router по умолчанию оставляет только asset-маршруты из этого
модуля. Даже при выключенной Dart OTA общий upload endpoint принимает только
загрузки assets; зарегистрированные Dart/toolchain upload tokens отклоняются.
Обычный Flutter APK не применит Dart-патч. Дальнейшая замена временного
Shorebird-derived формата собственным GhostEcos toolchain остаётся отдельной
работой.

## Проверки

`pytest -q test_code_ota.py test_publish_asset_ota.py` — 13 тестов проходят;
отдельная проверка RSA-подписи сервера пропускается в локальном Python-
окружении без `cryptography` (основная GhostEcos-служба уже использует эту
библиотеку). На стороне Flutter проверены оба формата RSA public key,
RSA-SHA256 подпись и обнаружение подмены манифеста. Nginx-конфиг локально
изменён, но его синтаксис и production-развёртывание ещё не проверены.
