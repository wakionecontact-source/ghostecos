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
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as wsstatus;
import '../theme.dart';
import 'auth_service.dart';

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

  bool get isConnected => _ch != null && !_authFail;

  /// Запустить или переподключиться. Если уже подключён — no-op.
  Future<void> connect() async {
    if (_authFail) return;
    if (_ch != null) return;
    final token = await AuthService.token();
    if (token == null || token.isEmpty) return;
    final url = '${GE.wsUrl}?token=${Uri.encodeComponent(token)}';
    try {
      final socket = await WebSocket.connect(url);
      _ch = IOWebSocketChannel(socket);
      _reconnectDelay = 1000;
      _lastRecv = DateTime.now();
      _connectedCtrl.add(true);
      _ch!.stream.listen(_onMessage, onDone: _onClose, onError: _onError);
      _startHeartbeat();
      if (kDebugMode) print('[WS] connected');
    } catch (e) {
      if (kDebugMode) print('[WS] connect failed: $e');
      _scheduleReconnect();
    }
  }

  void _startHeartbeat() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      try {
        _ch?.sink.add('ping');
        _lastPing = DateTime.now();
        _pongTimeout?.cancel();
        _pongTimeout = Timer(const Duration(seconds: 10), () {
          if (_lastRecv.isBefore(_lastPing)) {
            if (kDebugMode) print('[WS] pong timeout → reconnect');
            _kill('pong timeout');
          }
        });
      } catch (e) {
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
      final list = _subs[type];
      if (list != null) {
        for (final s in List.of(list)) {
          try { s.handler(data); } catch (e) {
            if (kDebugMode) print('[WS handler $type] $e');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) print('[WS parse] $e');
    }
  }

  void _onClose() {
    final code = _ch?.closeCode;
    if (kDebugMode) print('[WS] closed code=$code');
    if (code == 1008 || code == 4401 || code == 4403) {
      _authFail = true;
      _connectedCtrl.add(false);
      return;
    }
    _cleanup();
    _scheduleReconnect();
  }

  void _onError(dynamic e) {
    if (kDebugMode) print('[WS] error $e');
    _kill('error');
  }

  void _kill(String reason) {
    if (kDebugMode) print('[WS] kill: $reason');
    _cleanup();
    _scheduleReconnect();
  }

  void _cleanup() {
    _pingTimer?.cancel();
    _pongTimeout?.cancel();
    try { _ch?.sink.close(wsstatus.normalClosure); } catch (_) {}
    _ch = null;
    _connectedCtrl.add(false);
  }

  void _scheduleReconnect() {
    if (_authFail) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: _reconnectDelay), connect);
    _reconnectDelay = (_reconnectDelay * 2).clamp(1000, 30000);
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
      if (kDebugMode) print('[WS send] $e');
    }
  }

  /// Полный сброс — при logout.
  Future<void> disconnect() async {
    _authFail = false;
    _reconnectTimer?.cancel();
    _cleanup();
  }
}
