# GhostEcos Desktop

Flutter-обёртка вокруг веб-версии `ghostecos.duckdns.org`. Один аккаунт — все продукты экосистемы (GhostChat, GhostSocial, GhostBank, GhostNation) в нативном окне.

## Что внутри

- **WebView2** для рендеринга — лёгкий, использует встроенный в Windows 11 Edge runtime
- **System tray icon** — сворачивание в трей, быстрый доступ к секциям
- **Native push-notifications** — Windows Toast / Linux libnotify
- **Autostart** — опционально запускать с системой
- **Single-instance** — повторный запуск фокусит существующее окно (TODO)

## Требования к сборке (Windows)

1. **Flutter 3.44+**
2. **Visual Studio Build Tools 2022** с workload «Desktop development with C++»
   - <https://aka.ms/vs/17/release/vs_BuildTools.exe> (~6 ГБ)
   - После установки перезагрузка
3. **WebView2 Runtime** — обычно уже есть в Windows 11. Для Windows 10 — отдельная установка

## Сборка

```bat
cd app\desktop_wrapper
flutter pub get
flutter build windows --release
```

Готовый `.exe`: `build\windows\x64\runner\Release\ghostecos_desktop.exe`

## MSIX installer

```bat
flutter pub run msix:create
```

`.msix`: `build\windows\x64\runner\Release\ghostecos_desktop.msix`

## Разработка

```bat
flutter run -d windows
```

## JS-bridge для уведомлений из веба

```javascript
window.chrome.webview.postMessage(JSON.stringify({
  type: 'notify',
  title: 'Новое сообщение',
  body: '@waki: привет'
}));
```

Flutter покажет нативный Windows Toast.
