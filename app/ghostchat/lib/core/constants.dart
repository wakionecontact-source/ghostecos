/// Глобальные константы GhostChat.
///
/// ВАЖНО (из истории проекта): приложение прошлой версии «умерло» после
/// подключения SSL — клиент слал HTTP, сервер принимал только HTTPS.
/// Поэтому ВСЕ запросы — строго https:// и wss://.
library;

class K {
  K._();

  // ── Сеть ──────────────────────────────────────────────────────────────────
  static const String host = 'ghostecos.duckdns.org';

  /// База для HTTP API. ТОЛЬКО https.
  static const String apiBase = 'https://$host';

  /// WebSocket. ТОЛЬКО wss. Роут на сервере: @app.websocket("/ws").
  static const String wsUrl = 'wss://$host/ws';

  // ── Таймауты / keepalive (из SIGNAL_SCHEMA) ─────────────────────────────────
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 30);

  /// Клиент шлёт ping каждые 5с; нет pong за 8с → реконнект.
  static const Duration wsPingInterval = Duration(seconds: 5);
  static const Duration wsPongTimeout = Duration(seconds: 8);
  static const Duration wsReconnectMin = Duration(seconds: 2);
  static const Duration wsReconnectMax = Duration(seconds: 30);

  /// Поллинг подтверждения входа с нового устройства.
  static const Duration loginPollInterval = Duration(seconds: 2);

  // ── Лимиты валидации (ТЗ пользователя) ──────────────────────────────────────
  // Имя (display_name): 2..100, любые символы КРОМЕ «тяжёлых».
  static const int nameMin = 2;
  static const int nameMax = 100;

  // Username: 3..60 БЕЗ учёта точек; только латиница/цифры/_/.; общая длина ≤ 64.
  static const int usernameMinNoDots = 3;
  static const int usernameMaxNoDots = 60;
  static const int usernameMaxTotal = 64;

  // Пароль: 8..150, любые КРОМЕ запрещённых (управляющие) и эмодзи.
  static const int passwordMin = 8;
  static const int passwordMax = 150;

  // ── Файлы ───────────────────────────────────────────────────────────────────
  static const int fileMaxBytes =
      100 * 1024 * 1024; // сервер: GC_FILE_MAX_MB=100

  // ── Прочее ───────────────────────────────────────────────────────────────────
  static const String appVersion = '1.2.2';
}
