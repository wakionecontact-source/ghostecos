// TriangleService — режим «Треугольник» (см. connection-modes.md): сервер
// только сводит двух СУЩЕСТВУЮЩИХ контактов (обменивается кандидатами через
// WS-реле p2p.signal), сами сообщения после успешного NAT-punch идут P2P
// напрямую по UDP, минуя сервер. Апгрейд существующего серверного чата, а
// не отдельный список чатов (как LAN) — интеграция в ChatRepo отдельным
// шагом, здесь только сам механизм обнаружения+punch+сессия.
//
// Ограничения (осознанные, не баги):
// - Симметричный NAT/CGNAT не пробьётся простым STUN — сессия просто не
//   подтвердится, вызывающий код должен молча продолжать слать через сервер.
// - "Атомарность" — не буквальная синхронизация по часам (мобильные часы
//   недостаточно точны), а burst: обе стороны шлют punch-пакеты пачкой в
//   течение нескольких секунд сразу по получении кандидатов друг друга —
//   этого достаточно, чтобы окна открытия NAT-мэппингов пересеклись.
// - UDP без чужой инфраструктуры — простой ack поверх, без сложной
//   retransmission-логики (это уровень интеграции в ChatRepo, TODO #49).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'crypto_v2.dart';
import 'ws_client.dart';

const _stunHost = '155.212.166.221';
const _stunPort = 47779;
const _punchWindow = Duration(seconds: 4);
const _punchInterval = Duration(milliseconds: 250);

class TrianglePeerKeys {
  final String username;
  final String devicePubB64; // шифруем ЭТИМ (CryptoV2.encryptV2)
  final String identityPubB64; // сверяем c from_id входящих — анти-спуфинг
  const TrianglePeerKeys({
    required this.username,
    required this.devicePubB64,
    required this.identityPubB64,
  });
}

class TriangleSession {
  final String username;
  final InternetAddress address;
  final int port;
  DateTime lastSeen;
  TriangleSession({
    required this.username,
    required this.address,
    required this.port,
    required this.lastSeen,
  });
}

class TriangleTextMessage {
  final String fromUsername;
  final String msgId;
  final String text;
  final int sentAtMs;
  const TriangleTextMessage({
    required this.fromUsername,
    required this.msgId,
    required this.text,
    required this.sentAtMs,
  });
}

class TriangleService {
  TriangleService._();
  static final TriangleService instance = TriangleService._();

  RawDatagramSocket? _socket;
  Completer<Map<String, dynamic>?>? _stunCompleter;

  final Map<String, TriangleSession> _sessions = {};
  final Map<String, TrianglePeerKeys> _attemptKeys = {};
  final Map<String, Completer<bool>> _attemptCompleters = {};
  final Map<String, Timer> _punchTimers = {};
  final Map<String, List<Map<String, dynamic>>> _peerCandidates = {};

  final _msgCtrl = StreamController<TriangleTextMessage>.broadcast();
  Stream<TriangleTextMessage> get onMessage => _msgCtrl.stream;

  final _sessionCtrl = StreamController<String>.broadcast();
  /// Username, для которого P2P-сессия только что подтвердилась (первый
  /// валидный punch/punch_ack от него).
  Stream<String> get onSessionConfirmed => _sessionCtrl.stream;

  final _incomingOfferCtrl = StreamController<String>.broadcast();
  /// Существующий контакт прислал triangle-offer. Чтобы ответить и начать
  /// punch, вызывающий код должен знать ключи этого контакта — зовите
  /// respondToOffer(peerKeys), либо просто игнорируйте (чат продолжит идти
  /// через сервер как обычно).
  Stream<String> get onIncomingOffer => _incomingOfferCtrl.stream;

  bool hasSession(String username) => _sessions.containsKey(username);
  TriangleSession? sessionFor(String username) => _sessions[username];

  Future<void> _ensureSocket() async {
    if (_socket != null) return;
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket!.listen(_onUdpEvent);
    WsClient.instance.on('p2p.signal', _onWsSignal);
  }

  Future<String> _localIp() async {
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return '';
  }

  Future<Map<String, dynamic>?> _queryStun() async {
    await _ensureSocket();
    for (var attempt = 0; attempt < 2; attempt++) {
      _stunCompleter = Completer<Map<String, dynamic>?>();
      try {
        _socket!.send(utf8.encode('stun'), InternetAddress(_stunHost), _stunPort);
      } catch (_) {}
      final result = await _stunCompleter!.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => null,
      );
      if (result != null) return result;
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> _myCandidates() async {
    final stun = await _queryStun();
    final localIp = await _localIp();
    return [
      if (localIp.isNotEmpty) {'ip': localIp, 'port': _socket!.port},
      if (stun != null) {'ip': stun['ip'], 'port': stun['port']},
    ];
  }

  /// Инициировать P2P-попытку с существующим серверным контактом. Не
  /// держит вызывающего дольше ~10с (STUN + сигналинг + punch-окно) — после
  /// этого вызывающий просто продолжает слать через сервер как раньше.
  Future<bool> attemptConnect(TrianglePeerKeys peer) async {
    if (_sessions.containsKey(peer.username)) return true;
    await _ensureSocket();
    _attemptKeys[peer.username] = peer;

    final myCandidates = await _myCandidates();
    if (myCandidates.isEmpty) {
      _attemptKeys.remove(peer.username);
      return false;
    }

    final completer = Completer<bool>();
    _attemptCompleters[peer.username] = completer;

    WsClient.instance.send('p2p.signal', {
      'to': peer.username,
      'payload': {'stage': 'offer', 'candidates': myCandidates},
    });

    final ok = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => false,
    );
    _attemptCompleters.remove(peer.username);
    if (!ok) {
      _attemptKeys.remove(peer.username);
      _punchTimers.remove(peer.username)?.cancel();
    }
    return ok;
  }

  Future<void> respondToOffer(TrianglePeerKeys peer) async {
    if (!_peerCandidates.containsKey(peer.username)) return;
    await _ensureSocket();
    _attemptKeys[peer.username] = peer;
    final myCandidates = await _myCandidates();
    WsClient.instance.send('p2p.signal', {
      'to': peer.username,
      'payload': {'stage': 'answer', 'candidates': myCandidates},
    });
    _startPunch(peer.username);
  }

  void _onWsSignal(Map<String, dynamic> data) {
    final fromUsername = data['from_username'] as String?;
    final payload = data['payload'] as Map<String, dynamic>?;
    if (fromUsername == null || payload == null) return;
    final stage = payload['stage'] as String?;
    final candidates = (payload['candidates'] as List? ?? [])
        .whereType<Map>()
        .map((c) => c.cast<String, dynamic>())
        .toList();
    if (candidates.isEmpty) return;
    _peerCandidates[fromUsername] = candidates;

    if (stage == 'offer') {
      _incomingOfferCtrl.add(fromUsername);
      return;
    }
    if (stage == 'answer') {
      _startPunch(fromUsername);
    }
  }

  void _startPunch(String username) {
    final keys = _attemptKeys[username];
    final candidates = _peerCandidates[username];
    if (keys == null || candidates == null) return;
    _punchTimers[username]?.cancel();
    final deadline = DateTime.now().add(_punchWindow);
    _punchTimers[username] = Timer.periodic(_punchInterval, (t) async {
      if (DateTime.now().isAfter(deadline) || _sessions.containsKey(username)) {
        t.cancel();
        _punchTimers.remove(username);
        return;
      }
      await _sendPacket(username, keys, candidates, {'type': 'punch'});
    });
  }

  Future<void> _sendPacket(
    String username,
    TrianglePeerKeys keys,
    List<Map<String, dynamic>> candidates,
    Map<String, dynamic> inner,
  ) async {
    try {
      final envelope = await CryptoV2.instance.encryptV2(
        base64Decode(keys.devicePubB64),
        utf8.encode(jsonEncode({
          ...inner,
          'from_id': CryptoV2.instance.identityPubB64,
        })),
      );
      final bytes = utf8.encode(envelope);
      for (final c in candidates) {
        try {
          _socket!.send(bytes, InternetAddress(c['ip'] as String), c['port'] as int);
        } catch (_) {}
      }
    } catch (_) {}
  }

  void _onUdpEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;
    final raw = utf8.decode(dg.data, allowMalformed: true);

    if (_stunCompleter != null && !_stunCompleter!.isCompleted) {
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        if (data.containsKey('ip') && data.containsKey('port')) {
          _stunCompleter!.complete(data);
          return;
        }
      } catch (_) {}
    }

    _handleEncrypted(raw, dg.address, dg.port);
  }

  Future<void> _handleEncrypted(String envelopeB64, InternetAddress fromAddr, int fromPort) async {
    try {
      final clear = await CryptoV2.instance.decryptForMe(envelopeB64);
      if (clear == null) return;
      final inner = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      final fromId = inner['from_id'] as String?;
      final type = inner['type'] as String?;

      String? username;
      for (final entry in _attemptKeys.entries) {
        if (entry.value.identityPubB64 == fromId) {
          username = entry.key;
          break;
        }
      }
      if (username == null) return; // не сверяемая identity — игнор (спуфинг/шум)

      if (type == 'punch' || type == 'punch_ack') {
        final isNew = !_sessions.containsKey(username);
        _sessions[username] = TriangleSession(
          username: username, address: fromAddr, port: fromPort, lastSeen: DateTime.now(),
        );
        _punchTimers.remove(username)?.cancel();
        if (type == 'punch') {
          // Отвечаем punch_ack тем же путём — наш собственный punch мог до
          // второй стороны не дойти (несимметричный punch не редкость).
          final keys = _attemptKeys[username]!;
          await _sendPacket(username, keys,
              [{'ip': fromAddr.address, 'port': fromPort}], {'type': 'punch_ack'});
        }
        if (isNew) {
          _attemptCompleters[username]?.complete(true);
          _sessionCtrl.add(username);
        }
        return;
      }

      if (type == 'msg') {
        _sessions[username] = TriangleSession(
          username: username, address: fromAddr, port: fromPort, lastSeen: DateTime.now(),
        );
        final msgId = inner['msg_id'] as String? ?? '';
        final text = inner['text'] as String? ?? '';
        final sentAt = (inner['sent_at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
        _msgCtrl.add(TriangleTextMessage(
          fromUsername: username, msgId: msgId, text: text, sentAtMs: sentAt,
        ));
        final keys = _attemptKeys[username];
        if (keys != null) {
          await _sendPacket(username, keys,
              [{'ip': fromAddr.address, 'port': fromPort}], {'type': 'msg_ack', 'msg_id': msgId});
        }
      }
    } catch (_) {}
  }

  /// Отправить текст напрямую P2P — только если сессия УЖЕ подтверждена
  /// (см. hasSession). Fire-once без ретраев здесь — надёжность (ack-wait,
  /// retry, fallback на сервер) добавляется на уровне интеграции в ChatRepo.
  Future<bool> sendText(String username, String msgId, String text) async {
    final session = _sessions[username];
    final keys = _attemptKeys[username];
    if (session == null || keys == null) return false;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await _sendPacket(
      username,
      keys,
      [{'ip': session.address.address, 'port': session.port}],
      {'type': 'msg', 'msg_id': msgId, 'text': text, 'sent_at': nowMs},
    );
    return true;
  }
}

final triangleService = TriangleService.instance;
