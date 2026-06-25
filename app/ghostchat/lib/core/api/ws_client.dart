/// WebSocket-клиент GhostChat.
///
/// • Подключается к wss://…/ws, шлёт первый пакет {type:auth, token, device_id}.
/// • Ping каждые 5с; если нет ЛЮБОГО входящего пакета за 8с → реконнект.
/// • Экспоненциальный backoff переподключения (2с → 30с).
/// • Раздаёт декодированные пакеты через [events].
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../constants.dart';
import '../storage/secure_store.dart';

enum WsStatus { disconnected, connecting, connected, authenticated }

class WsClient {
  WsClient._();
  static final WsClient I = WsClient._();

  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _ping;
  Timer? _pongDeadline;
  Timer? _reconnect;
  bool _manualClose = false;
  Duration _backoff = K.wsReconnectMin;

  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _statusCtrl = StreamController<WsStatus>.broadcast();
  WsStatus _status = WsStatus.disconnected;

  Stream<Map<String, dynamic>> get events => _events.stream;
  Stream<WsStatus> get status => _statusCtrl.stream;
  WsStatus get currentStatus => _status;

  void _setStatus(WsStatus s) {
    _status = s;
    if (!_statusCtrl.isClosed) _statusCtrl.add(s);
  }

  Future<void> connect() async {
    _manualClose = false;
    final token = await SecureStore.I.token;
    if (token == null || token.isEmpty) return;
    await _open(token);
  }

  Future<void> _open(String token) async {
    _setStatus(WsStatus.connecting);
    try {
      _ch = WebSocketChannel.connect(Uri.parse(K.wsUrl));
      await _ch!.ready;
      _setStatus(WsStatus.connected);
      _sub = _ch!.stream.listen(
        _onData,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
      final deviceId = await SecureStore.I.deviceId ?? '';
      send({'type': 'auth', 'token': token, 'device_id': deviceId});
      _startPing();
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onData(dynamic raw) {
    _armPongDeadline(); // любой входящий пакет = соединение живо
    Map<String, dynamic> pkt;
    try {
      pkt = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final t = pkt['type'];
    if (t == 'pong') return;
    if (t == 'auth_ok') {
      _setStatus(WsStatus.authenticated);
      _backoff = K.wsReconnectMin; // успешная авторизация — сбросить backoff
    }
    if (!_events.isClosed) _events.add(pkt);
  }

  void send(Map<String, dynamic> pkt) {
    try {
      _ch?.sink.add(jsonEncode(pkt));
    } catch (_) {}
  }

  void _startPing() {
    _ping?.cancel();
    _armPongDeadline();
    _ping = Timer.periodic(K.wsPingInterval, (_) => send({'type': 'ping'}));
  }

  void _armPongDeadline() {
    _pongDeadline?.cancel();
    _pongDeadline = Timer(K.wsPongTimeout, _scheduleReconnect);
  }

  void _scheduleReconnect() {
    _cleanup();
    if (_manualClose) return;
    _setStatus(WsStatus.disconnected);
    _reconnect?.cancel();
    _reconnect = Timer(_backoff, () async {
      final next = (_backoff.inSeconds * 2).clamp(
        K.wsReconnectMin.inSeconds,
        K.wsReconnectMax.inSeconds,
      );
      _backoff = Duration(seconds: next);
      final token = await SecureStore.I.token;
      if (token != null && token.isNotEmpty) await _open(token);
    });
  }

  void _cleanup() {
    _ping?.cancel();
    _pongDeadline?.cancel();
    _sub?.cancel();
    _sub = null;
    try {
      _ch?.sink.close();
    } catch (_) {}
    _ch = null;
  }

  Future<void> disconnect() async {
    _manualClose = true;
    _reconnect?.cancel();
    _cleanup();
    _setStatus(WsStatus.disconnected);
  }
}
