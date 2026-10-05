// WebSocket-клиент для real-time событий Ghost.
//
// Подключается к GE.wsUrl с ?token=<auth_token>. Auto-reconnect c exp backoff,
// heartbeat ping каждые 25 сек, pong-timeout 10 сек → kill stale.
//
// Подписки: events.listen(type, callback) — например 'chat.new', 'chat.delivered',
// 'chat.read', 'chat.typing', 'group.new', 'presence', и т.д.
//
// Использование:
//   WsClient.instance.connect();
//   final sub = WsClient.instance.on('chat.new', (data) { ... });
//   sub.cancel();

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as wsstatus;
import '../theme.dart';
import 'auth_service.dart';
import '../core/local/app_logger.dart';

/// Ошибка RPC-вызова (сервер ответил `<type>.err`).
class WsRpcException implements Exception {
  final String message;
  WsRpcException(this.message);
  @override
  String toString() => message;
}

typedef WsHandler = void Function(Map<String, dynamic> data);

class _Subscription {
  final String type;
  final WsHandler handler;
  final void Function() _onCancel;
  _Subscription(this.type, this.handler, this._onCancel);
  void cancel() => _onCancel();
}

class WsClient {
  WsClient._();
  static final WsClient instance = WsClient._();

  IOWebSocketChannel? _ch;
  bool _authFail = false;
  Timer? _pingTimer;
  Timer? _pongTimeout;
  Timer? _reconnectTimer;
  int _reconnectDelay = 1000;
  DateTime _lastRecv = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPing = DateTime.fromMillisecondsSinceEpoch(0);

  final Map<String, List<_Subscription>> _subs = {};
  final StreamController<bool> _connectedCtrl = StreamController.broadcast();
  Stream<bool> get onConnectionChange => _connectedCtrl.stream;

  // ── RPC (call/response по request_id) ──────────────────────────────────
  final Map<String, Completer<Map<String, dynamic>>> _pendingRpc = {};
  final _rng = Random.secure();

  bool get isConnected => _ch != null && !_authFail;

  /// Запустить или переподключиться. Если уже подключён — no-op.
  Future<void> connect() async {
    if (_authFail) return;
    if (_ch != null) return;
    final token = await AuthService.token();
    if (token == null || token.isEmpty) return;
    final deviceId = await AuthService.deviceId();
    final url =
        '${GE.wsUrl}?token=${Uri.encodeComponent(token)}'
        '&device_id=${Uri.encodeComponent(deviceId)}';
    try {
      final socket = await WebSocket.connect(url);
      _ch = IOWebSocketChannel(socket);
      _reconnectDelay = 1000;
      _lastRecv = DateTime.now();
      _connectedCtrl.add(true);
      _ch!.stream.listen(_onMessage, onDone: _onClose, onError: _onError);
      _startHeartbeat();
      appLog.info('ws', 'connected');
    } catch (e) {
      appLog.warn('ws', 'connect failed: $e');
      _scheduleReconnect();
    }
  }

  void _startHeartbeat() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      try {
        _ch?.sink.add('ping');
        _lastPing = DateTime.now();
        _pongTimeout?.cancel();
        _pongTimeout = Timer(const Duration(seconds: 20), () {
          if (_lastRecv.isBefore(_lastPing)) {
            appLog.warn('ws', 'pong timeout — reconnecting');
            _kill('pong timeout');
          }
        });
      } catch (e) {
        appLog.warn('ws', 'ping send failed: $e');
        _kill('ping send failed');
      }
    });
  }

  void _onMessage(dynamic raw) {
    _lastRecv = DateTime.now();
    if (raw == 'pong') return;
    if (raw is! String || raw.isEmpty || raw[0] != '{') return;
    try {
      final ev = jsonDecode(raw) as Map<String, dynamic>;
      final type = ev['type'] as String?;
      final data = (ev['data'] as Map?)?.cast<String, dynamic>() ?? {};
      if (type == null) return;
      // RPC-ответ: <type>.ok / <type>.err с тем же request_id, что мы слали.
      if (type.endsWith('.ok') || type.endsWith('.err')) {
        final rid = data['request_id'] as String?;
        final completer = rid != null ? _pendingRpc.remove(rid) : null;
        if (completer != null && !completer.isCompleted) {
          if (type.endsWith('.ok')) {
            completer.complete(data);
          } else {
            completer.completeError(
              WsRpcException((data['error'] as String?) ?? 'Ошибка сервера'),
            );
          }
          return; // RPC-ответы не дублируем в обычные .on()-подписки
        }
      }
      final list = _subs[type];
      if (list != null) {
        for (final s in List.of(list)) {
          try {
            s.handler(data);
          } catch (e) {
            appLog.error('ws', 'handler $type failed: $e');
          }
        }
      }
    } catch (e) {
      appLog.warn('ws', 'message parse failed: $e');
    }
  }

  void _onClose() {
    final code = _ch?.closeCode;
    appLog.info('ws', 'closed code=$code');
    if (code == 4401 || code == 4403) {
      unawaited(
        AuthService.invalidateSession(
          reason: code == 4401 ? 'Недействительный токен' : 'Сессия отклонена',
        ),
      );
      _authFail = true;
      _connectedCtrl.add(false);
      return;
    }
    if (code == 1008) {
      _authFail = true;
      _connectedCtrl.add(false);
      return;
    }
    _cleanup();
    _scheduleReconnect();
  }

  void _onError(dynamic e) {
    appLog.warn('ws', 'error: $e');
    _kill('error');
  }

  void _kill(String reason) {
    appLog.warn('ws', 'kill: $reason');
    _cleanup();
    _scheduleReconnect();
  }

  void _cleanup() {
    _pingTimer?.cancel();
    _pongTimeout?.cancel();
    try {
      _ch?.sink.close(wsstatus.normalClosure);
    } catch (_) {}
    _ch = null;
    _connectedCtrl.add(false);
    // Не оставляем RPC висеть до таймаута — соединение уже мертво, дальше
    // reconnect может занять секунды, а caller ждёт ответ прямо сейчас.
    for (final c in _pendingRpc.values) {
      if (!c.isCompleted) {
        c.completeError(WsRpcException('Соединение разорвано'));
      }
    }
    _pendingRpc.clear();
  }

  void _scheduleReconnect() {
    if (_authFail) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: _reconnectDelay), connect);
    // Потолок 8с (был 30с): быстрее восстанавливаемся в фоне → меньше окно, в
    // которое входящие пропускаются (на реконнекте ChatRepo догоняет pending).
    _reconnectDelay = (_reconnectDelay * 2).clamp(1000, 8000);
  }

  /// Подписаться на событие по типу. Возвращает _Subscription с .cancel().
  _Subscription on(String type, WsHandler handler) {
    final list = _subs.putIfAbsent(type, () => []);
    late _Subscription sub;
    sub = _Subscription(type, handler, () {
      list.remove(sub);
      if (list.isEmpty) _subs.remove(type);
    });
    list.add(sub);
    return sub;
  }

  /// Отправить кастомное событие (например `chat.typing`).
  void send(String type, Map<String, dynamic> data) {
    try {
      _ch?.sink.add(jsonEncode({'type': type, 'data': data}));
    } catch (e) {
      appLog.warn('ws', 'send $type failed: $e');
    }
  }

  String _reqId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(16, (_) => chars[_rng.nextInt(chars.length)]).join();
  }

  /// RPC-вызов: шлёт {type, data: {...data, request_id}}, ждёт ответ
  /// `<type>.ok`/`<type>.err` с тем же request_id. Подключается лениво —
  /// первый .call() в приложении сам открывает сокет (см. WsClient docs).
  /// Бросает [WsRpcException] на `.err`, [TimeoutException] если сервер
  /// не ответил за [timeout].
  Future<Map<String, dynamic>> call(
    String type, [
    Map<String, dynamic> data = const {},
    Duration timeout = const Duration(seconds: 12),
  ]) async {
    if (!isConnected) await connect();
    if (!isConnected) {
      throw WsRpcException('Нет соединения с сервером');
    }
    final rid = _reqId();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRpc[rid] = completer;
    send(type, {...data, 'request_id': rid});
    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          _pendingRpc.remove(rid);
          throw WsRpcException('Сервер не ответил вовремя ($type)');
        },
      );
    } finally {
      _pendingRpc.remove(rid);
    }
  }

  /// Полный сброс — при logout.
  Future<void> disconnect() async {
    _authFail = false;
    _reconnectTimer?.cancel();
    _cleanup();
  }
}
