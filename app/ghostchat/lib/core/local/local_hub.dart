import 'dart:async';
import 'dart:convert';
import 'app_logger.dart';
import 'local_transport.dart';
import 'lan_settings.dart';

/// Grouped request from one device across multiple transports
class LocalGroupedRequest {
  final String deviceId;
  final Set<TransportType> transports;
  final Map<TransportType, LocalPeer> peers; // one per transport
  int? pingMs; // latency from best transport

  LocalGroupedRequest({required this.deviceId})
      : transports = {},
        peers = {};

  /// Best peer based on transport priority
  LocalPeer get bestPeer {
    final priority = LanSettings().lanTransportPriority;
    for (final t in priority) {
      if (peers.containsKey(t)) return peers[t]!;
    }
    return peers.values.first;
  }

  String get label => deviceId.length > 8 ? '${deviceId.substring(0, 8)}...' : deviceId;
}

/// Aggregates all local transports (LAN, WiFi Direct, Bluetooth)
/// and exposes merged streams for the UI.
class LocalHub {
  static final LocalHub _i = LocalHub._();
  factory LocalHub() => _i;
  LocalHub._();

  final List<LocalTransport> _transports = [];

  // Track which transports actually started successfully
  final Set<TransportType> _startedTransports = {};
  Set<TransportType> get startedTransports => Set.unmodifiable(_startedTransports);

  // Debounce: collect requests for 2 sec, then emit grouped
  final Map<String, LocalGroupedRequest> _pendingRequests = {};
  final Map<String, Timer> _debounceTimers = {};

  // Merged broadcast streams
  final _groupedRequestCtrl = StreamController<LocalGroupedRequest>.broadcast();
  final _collectingCtrl = StreamController<LocalPeer>.broadcast();
  final _requestCtrl = StreamController<LocalPeer>.broadcast();
  final _acceptCtrl  = StreamController<LocalPeer>.broadcast();
  final _msgCtrl     = StreamController<LocalMessageEvent>.broadcast();
  final _ackCtrl     = StreamController<LocalAckEvent>.broadcast();
  final _seenCtrl    = StreamController<LocalSeenEvent>.broadcast();

  Stream<LocalGroupedRequest> get onGroupedRequest => _groupedRequestCtrl.stream;
  /// Первый сигнал от нового device_id — ДО того, как окно сбора (5 сек)
  /// закроется. UI показывает "Подождите..." с этим UUID сразу же.
  Stream<LocalPeer>         get onCollecting => _collectingCtrl.stream;
  Stream<LocalPeer>         get onRequest => _requestCtrl.stream;
  Stream<LocalPeer>         get onAccept  => _acceptCtrl.stream;
  Stream<LocalMessageEvent> get onMessage => _msgCtrl.stream;
  Stream<LocalAckEvent>     get onAck     => _ackCtrl.stream;
  Stream<LocalSeenEvent>    get onSeen    => _seenCtrl.stream;

  final List<StreamSubscription> _subs = [];

  // Transport username → transport type mapping
  final Map<String, TransportType> _sessionMap = {};

  // Ping latency per peer (username → ms)
  final Map<String, int> _pingLatency = {};
  int? getPingMs(String username) => _pingLatency[username];

  // Способы связи, которые СЕЙЧАС реально доступны у пира (пришло в
  // последнем ping/pong, а не "транспорт когда-то стартовал").
  final Map<String, Set<TransportType>> _peerAvailable = {};
  Set<TransportType>? availableTransportsFor(String username) => _peerAvailable[username];

  // Keepalive timers
  final Map<String, Timer> _keepaliveTimers = {};
  final Map<String, DateTime> _lastPingSent = {};
  final Map<String, DateTime> _lastPongRecv = {};

  // Online status
  final Map<String, bool> _onlineStatus = {};
  bool isOnline(String username) => _onlineStatus[username] ?? false;

  final _onlineCtrl = StreamController<MapEntry<String, bool>>.broadcast();
  Stream<MapEntry<String, bool>> get onOnlineChanged => _onlineCtrl.stream;

  bool _registered = false;

  void register(LocalTransport t) {
    _transports.add(t);
  }

  /// Register all local transports exactly once (idempotent).
  void registerDefaults(List<LocalTransport> transports) {
    if (_registered) return;
    _registered = true;
    for (final t in transports) {
      register(t);
    }
  }

  Future<void> startAll() async {
    await LanSettings().load();
    for (final s in _subs) { s.cancel(); }
    _subs.clear();
    _startedTransports.clear();

    final settings = LanSettings();
    for (final t in _transports) {
      // Check if this transport is enabled in settings
      if (!settings.isLanTransportEnabled(t.type)) {
        appLog.info('lan', '${transportLabel(t.type)} отключён в настройках');
        continue;
      }

      try {
        await t.start();
        _startedTransports.add(t.type);
        appLog.info('lan', '${transportLabel(t.type)} запущен');
      } catch (e) {
        appLog.error('lan', '${transportLabel(t.type)} не удалось запустить: $e');
        continue;
      }
      _subs.add(t.onRequest.listen(_onRawRequest));
      _subs.add(t.onAccept.listen((p) {
        appLog.info('lan', 'Accept от device=${p.deviceId} (${transportLabel(p.transport)})');
        _sessionMap[p.deviceId] = p.transport;
        _acceptCtrl.add(p);
        _startKeepalive(p.deviceId);
      }));
      _subs.add(t.onMessage.listen((m) {
        // Handle keepalive pong
        if (m.msgId == '__pong__') {
          _handlePong(m.fromUsername, m.encB64);
          return;
        }
        if (m.msgId == '__ping__') {
          _handlePingReceived(m.fromUsername, m.encB64);
          return;
        }
        _msgCtrl.add(m);
      }));
      _subs.add(t.onAck.listen((a) => _ackCtrl.add(a)));
      _subs.add(t.onSeen.listen((s) => _seenCtrl.add(s)));
    }
  }

  Future<void> stopAll() async {
    for (final s in _subs) { s.cancel(); }
    _subs.clear();
    for (final t in _transports) { await t.stop(); }
    _startedTransports.clear();
    _sessionMap.clear();
    _pendingRequests.clear();
    for (final t in _debounceTimers.values) { t.cancel(); }
    _debounceTimers.clear();
    for (final t in _keepaliveTimers.values) { t.cancel(); }
    _keepaliveTimers.clear();
    _pingLatency.clear();
    _onlineStatus.clear();
  }

  /// Handle raw request from a single transport — собираем сигналы одного
  /// device_id "окном" в 5 сек: каждый НОВЫЙ сигнал (в т.ч. с другого
  /// транспорта) продлевает окно ещё на 5 сек, пока сигналы не перестанут
  /// приходить. Цель — понять ВСЕ способы связи с устройством, а не решить
  /// по первому же сигналу.
  void _onRawRequest(LocalPeer peer) {
    final did = peer.deviceId;
    if (did.isEmpty) return;

    // Check if we should accept requests from this transport
    if (!LanSettings().isLanTransportEnabled(peer.transport)) return;
    if (LanSettings().isLanDeviceBlocked(did)) return;

    final isNewGroup = !_pendingRequests.containsKey(did);
    final group = _pendingRequests.putIfAbsent(
      did, () => LocalGroupedRequest(deviceId: did),
    );
    group.transports.add(peer.transport);
    group.peers[peer.transport] = peer;

    appLog.debug('lan', 'Запрос от $did (${transportLabel(peer.transport)})');
    if (isNewGroup) _collectingCtrl.add(peer);
    // Reset debounce timer
    _debounceTimers[did]?.cancel();
    _debounceTimers[did] = Timer(const Duration(seconds: 5), () {
      final req = _pendingRequests.remove(did);
      _debounceTimers.remove(did);
      if (req != null) {
        appLog.info('lan', 'Grouped request: ${req.deviceId} (${req.transports.map(transportLabel).join(", ")})');
        _groupedRequestCtrl.add(req);
      }
    });

    // Also forward raw for backward compat
    _requestCtrl.add(peer);
  }

  // ── Keepalive (every 10 sec) ───────────────────────────────────────────

  void _startKeepalive(String username) {
    if (!LanSettings().lanPingEnabled) return;
    _keepaliveTimers[username]?.cancel();
    _onlineStatus[username] = true;
    _onlineCtrl.add(MapEntry(username, true));

    _keepaliveTimers[username] = Timer.periodic(
      const Duration(seconds: 10), (_) => _sendPing(username),
    );
  }

  void _stopKeepalive(String username) {
    _keepaliveTimers[username]?.cancel();
    _keepaliveTimers.remove(username);
    _onlineStatus[username] = false;
    _onlineCtrl.add(MapEntry(username, false));
  }

  /// Способы связи, которые СЕЙЧАС реально живы у меня (не "транспорт
  /// когда-то стартовал", а "проверили прямо перед отправкой") — кладём в
  /// тело ping/pong, чтобы собеседник знал, чем реально можно достучаться.
  Future<String> _myAvailabilityPayload() async {
    final available = <String>[];
    for (final t in _transports) {
      if (!LanSettings().isLanTransportEnabled(t.type)) continue;
      try {
        if (await t.isCurrentlyAvailable()) available.add(t.type.name);
      } catch (_) {}
    }
    return jsonEncode({'t': available});
  }

  Set<TransportType> _parseAvailability(String payload) {
    if (payload.isEmpty) return {};
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final list = (data['t'] as List? ?? []).cast<String>();
      return list.map((n) {
        return TransportType.values.firstWhere(
          (v) => v.name == n,
          orElse: () => TransportType.lan,
        );
      }).toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> _sendPing(String username) async {
    final t = transportFor(username);
    if (t == null) {
      _stopKeepalive(username);
      return;
    }
    _lastPingSent[username] = DateTime.now();
    try {
      final payload = await _myAvailabilityPayload();
      await t.sendMessage(username, '__ping__', payload, 0);
      // If no pong within 15 sec, mark offline
      Future.delayed(const Duration(seconds: 15), () {
        final lastPong = _lastPongRecv[username];
        final lastPing = _lastPingSent[username];
        if (lastPing != null && (lastPong == null || lastPong.isBefore(lastPing))) {
          if (_onlineStatus[username] == true) {
            _onlineStatus[username] = false;
            _onlineCtrl.add(MapEntry(username, false));
          }
        }
      });
    } catch (_) {
      _stopKeepalive(username);
    }
  }

  Future<void> _handlePingReceived(String fromUsername, String payload) async {
    if (payload.isNotEmpty) _peerAvailable[fromUsername] = _parseAvailability(payload);
    // Reply with pong — тоже несёт НАШУ доступность.
    final t = transportFor(fromUsername);
    if (t != null) {
      final myPayload = await _myAvailabilityPayload();
      t.sendMessage(fromUsername, '__pong__', myPayload, DateTime.now().millisecondsSinceEpoch);
    }
  }

  void _handlePong(String fromUsername, String payload) {
    if (payload.isNotEmpty) _peerAvailable[fromUsername] = _parseAvailability(payload);
    _lastPongRecv[fromUsername] = DateTime.now();
    final sent = _lastPingSent[fromUsername];
    if (sent != null) {
      final ms = DateTime.now().difference(sent).inMilliseconds;
      _pingLatency[fromUsername] = ms;
      appLog.debug('lan', 'pong от $fromUsername: ${ms}ms');
    }
    if (_onlineStatus[fromUsername] != true) {
      _onlineStatus[fromUsername] = true;
      _onlineCtrl.add(MapEntry(fromUsername, true));
    }
  }

  // ── Transport priority ─────────────────────────────────────────────────

  /// Select best transport for a peer based on configured priority
  LocalTransport? _bestTransport(String username) {
    final priority = LanSettings().lanTransportPriority;
    for (final type in priority) {
      for (final t in _transports) {
        if (t.type == type && t.hasSession(username)) return t;
      }
    }
    // Fallback: any available
    for (final t in _transports) {
      if (t.hasSession(username)) return t;
    }
    return null;
  }

  // ── Public API ─────────────────────────────────────────────────────────

  Future<void> discoverAll() async {
    appLog.info('lan', 'discoverAll: ${_transports.length} транспортов');
    for (final t in _transports) {
      final enabled = LanSettings().isLanTransportEnabled(t.type);
      appLog.debug('lan', '${transportLabel(t.type)}: enabled=$enabled');
      if (enabled) {
        t.discover();
      }
    }
  }

  /// Find which transport has a session with this user (respects priority)
  LocalTransport? transportFor(String username) {
    return _bestTransport(username);
  }

  void trackSession(String username, TransportType type) {
    _sessionMap[username] = type;
    _startKeepalive(username);
  }

  bool hasSession(String username) => transportFor(username) != null;

  List<int>? getKey(String username) => transportFor(username)?.getKey(username);

  Future<void> sendMessage(String toUsername, String msgId, String encB64, int sentAt, {String replyToMsgId = ''}) async {
    final t = transportFor(toUsername);
    if (t == null) return;
    await t.sendMessage(toUsername, msgId, encB64, sentAt, replyToMsgId: replyToMsgId);
  }

  Future<void> sendSeen(String toUsername, List<String> msgIds) async {
    final t = transportFor(toUsername);
    if (t == null) return;
    await t.sendSeen(toUsername, msgIds);
  }

  Future<void> sendAccept(LocalPeer peer) async {
    for (final t in _transports) {
      if (t.type == peer.transport) {
        await t.sendAccept(peer);
        _sessionMap[peer.deviceId] = peer.transport;
        _startKeepalive(peer.deviceId);
        return;
      }
    }
  }

  void blockPeer(LocalPeer peer) {
    for (final t in _transports) {
      t.blockPeer(peer.deviceId, peer.address);
    }
  }

  /// Block by device_id across all transports
  void blockDeviceId(String deviceId) {
    for (final t in _transports) {
      t.blockPeer(deviceId, '');
    }
  }

  /// Get signal quality string based on ping latency
  String signalQuality(String username) {
    final ms = _pingLatency[username];
    if (ms == null) return '';
    if (ms < 50) return 'отлично';
    if (ms < 200) return 'хорошо';
    return 'слабо';
  }

  /// Signal bars: 3 = excellent, 2 = good, 1 = poor, 0 = unknown
  int signalBars(String username) {
    final ms = _pingLatency[username];
    if (ms == null) return 0;
    if (ms < 50) return 3;
    if (ms < 200) return 2;
    return 1;
  }

  /// Get list of registered transport types
  List<TransportType> get availableTransports => _transports.map((t) => t.type).toList();
}

final localHub = LocalHub();
