import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../app_logger.dart';
import '../local_transport.dart';
import '../lan_identity.dart';
import '../../../services/auth_service.dart';
import '../../../services/crypto_v2.dart';

class _LanSession {
  final String   ip;
  final List<int> key; // peer's static X25519 device pub bytes
  _LanSession({required this.ip, required this.key});
}

class LanTransport implements LocalTransport {
  @override
  TransportType get type => TransportType.lan;

  // Streams
  final _requestCtrl = StreamController<LocalPeer>.broadcast();
  final _acceptCtrl  = StreamController<LocalPeer>.broadcast();
  final _msgCtrl     = StreamController<LocalMessageEvent>.broadcast();
  final _ackCtrl     = StreamController<LocalAckEvent>.broadcast();
  final _seenCtrl    = StreamController<LocalSeenEvent>.broadcast();

  @override Stream<LocalPeer>         get onRequest => _requestCtrl.stream;
  @override Stream<LocalPeer>         get onAccept  => _acceptCtrl.stream;
  @override Stream<LocalMessageEvent> get onMessage => _msgCtrl.stream;
  @override Stream<LocalAckEvent>     get onAck     => _ackCtrl.stream;
  @override Stream<LocalSeenEvent>    get onSeen    => _seenCtrl.stream;

  RawDatagramSocket? _udp;
  ServerSocket?      _tcp;
  bool _running = false;

  String? _myDeviceId; // cached
  final Map<String, _LanSession> _sessions = {};
  final Set<String> _blockedDeviceIds = {};
  final Set<String> _blockedIps       = {};

  @override
  List<int>? getKey(String username) => _sessions[username]?.key;

  String? getPeerIp(String username) => _sessions[username]?.ip;

  @override
  void storeSession(String username, String address, List<int> key) {
    _sessions[username] = _LanSession(ip: address, key: key);
  }

  @override
  bool hasSession(String username) => _sessions.containsKey(username);

  @override
  void blockPeer(String deviceId, String address) {
    if (deviceId.isNotEmpty) _blockedDeviceIds.add(deviceId);
    if (address.isNotEmpty)  _blockedIps.add(address);
  }

  @override
  bool isBlocked(String deviceId, String address) =>
      _blockedDeviceIds.contains(deviceId) || _blockedIps.contains(address);

  @override
  Future<void> start() async {
    if (_running) return;
    // Close previous sockets if they weren't cleaned up
    _udp?.close();
    _udp = null;
    if (_tcp != null) {
      await _tcp!.close();
      _tcp = null;
      // Give OS time to release the port
      await Future.delayed(const Duration(milliseconds: 500));
    }
    _running = true;
    _myDeviceId = await AuthService.deviceId();
    await CryptoV2.instance.ensureKeys();
    await _startUdp();
    await _startTcp();
  }

  @override
  Future<void> stop() async {
    _running = false;
    _udp?.close();
    _udp = null;
    if (_tcp != null) {
      await _tcp!.close();
      _tcp = null;
    }
    _sessions.clear();
  }

  // ── UDP listener on 47777 ─────────────────────────────────────────────────

  Future<void> _startUdp() async {
    // Try bind with retry — port may be held by previous instance
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 47777,
            reuseAddress: true, reusePort: false);
        _udp!.broadcastEnabled = true;
        appLog.info('lan', 'UDP слушает на :47777');
        _udp!.listen((event) async {
          if (event != RawSocketEvent.read) return;
          final dg = _udp?.receive();
          if (dg == null) return;
          try {
            final pkt = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
            if (pkt['type'] != 'discover') return;
            final deviceId = pkt['device_id'] as String? ?? '';
            if (deviceId.isEmpty || deviceId == _myDeviceId) return;
            final x25519Pub = pkt['x25519_pub'] as String? ?? '';
            final identityPub = pkt['identity_pub'] as String? ?? '';
            final sig = pkt['signed_prekey_sig'] as String? ?? '';
            final senderIp = dg.address.address;
            appLog.info('lan', '← discover от $senderIp device=$deviceId');
            if (isBlocked(deviceId, senderIp)) {
              appLog.debug('lan', 'Заблокирован: $deviceId / $senderIp');
              return;
            }
            final verified = await verifyPeerIdentity(
              x25519PubB64: x25519Pub,
              identityPubB64: identityPub,
              signedPrekeySigB64: sig,
            );
            if (!verified) return;
            _requestCtrl.add(LocalPeer(
              peerId:       '$deviceId@$senderIp',
              address:      senderIp,
              deviceId:     deviceId,
              x25519PubB64: x25519Pub,
              identityPubB64: identityPub,
              signedPrekeySigB64: sig,
              transport:    TransportType.lan,
            ));
          } catch (_) {}
        });
        return; // success
      } catch (e) {
        appLog.debug('lan', 'UDP bind попытка ${attempt + 1}/3 ошибка: $e');
        _udp?.close();
        _udp = null;
        if (attempt < 2) await Future.delayed(const Duration(seconds: 1));
      }
    }
    appLog.debug('lan', 'UDP bind не удался после 3 попыток — LAN (LanTransport) discover не будет работать');
  }

  // ── TCP listener on 47778 ─────────────────────────────────────────────────

  Future<void> _startTcp() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        _tcp = await ServerSocket.bind(InternetAddress.anyIPv4, 47778, shared: true);
        appLog.info('lan', 'TCP слушает на :47778');
        break; // success
      } catch (e) {
        appLog.debug('lan', 'TCP bind попытка ${attempt + 1}/3 ошибка: $e');
        if (_tcp != null) { await _tcp!.close(); _tcp = null; }
        if (attempt < 2) {
          await Future.delayed(Duration(seconds: 2 + attempt));
          continue;
        }
        appLog.debug('lan', 'TCP bind не удался — LAN (LanTransport) не будет работать');
        return;
      }
    }
    if (_tcp == null) return;
    try {
      _tcp!.listen((socket) async {
        final remoteIp = socket.remoteAddress.address;
        try {
          final bytes = await socket
              .fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));
          socket.destroy();
          final pkt  = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
          final type = pkt['type'] as String? ?? '';

          appLog.debug('lan', 'TCP ← $type от $remoteIp');
          if (type == 'accept') {
            final deviceId  = pkt['device_id']  as String? ?? '';
            final x25519Pub = pkt['x25519_pub'] as String? ?? '';
            final identityPub = pkt['identity_pub'] as String? ?? '';
            final sig = pkt['signed_prekey_sig'] as String? ?? '';
            if (deviceId.isEmpty) return;
            appLog.info('lan', '← accept от $remoteIp device=$deviceId');

            final verified = await verifyPeerIdentity(
              x25519PubB64: x25519Pub,
              identityPubB64: identityPub,
              signedPrekeySigB64: sig,
            );
            if (!verified) return;

            if (x25519Pub.isNotEmpty) {
              try {
                storeSession(deviceId, remoteIp, base64.decode(x25519Pub));
              } catch (_) {}
            }

            _acceptCtrl.add(LocalPeer(
              peerId:       '$deviceId@$remoteIp',
              deviceId:     deviceId,
              x25519PubB64: x25519Pub,
              identityPubB64: identityPub,
              signedPrekeySigB64: sig,
              transport:    TransportType.lan,
              address:      remoteIp,
            ));
          } else if (type == 'message') {
            final fromDeviceId = pkt['from']    as String? ?? '';
            final msgId        = pkt['msg_id']  as String? ?? '';
            final encB64       = pkt['enc_body'] as String? ?? '';
            final sentAt       = (pkt['sent_at'] as num?)?.toInt() ?? 0;
            final replyTo      = pkt['reply_to_msg_id'] as String? ?? '';
            if (fromDeviceId.isEmpty || msgId.isEmpty) return;

            // Update IP for this device
            if (_sessions.containsKey(fromDeviceId)) {
              final s = _sessions[fromDeviceId]!;
              _sessions[fromDeviceId] = _LanSession(ip: remoteIp, key: s.key);
            }

            // Auto-send delivery ack
            _sendTcp(remoteIp, jsonEncode({
              'type':   'ack',
              'from':   _myDeviceId ?? '',
              'msg_id': msgId,
            }));

            _msgCtrl.add(LocalMessageEvent(
              fromUsername: fromDeviceId,
              msgId:        msgId,
              encB64:       encB64,
              sentAt:       sentAt,
              replyToMsgId: replyTo,
              transport:    TransportType.lan,
            ));
          } else if (type == 'ack') {
            final from  = pkt['from']   as String? ?? '';
            final msgId = pkt['msg_id'] as String? ?? '';
            if (from.isEmpty || msgId.isEmpty) return;
            _ackCtrl.add(LocalAckEvent(fromUsername: from, msgId: msgId));
          } else if (type == 'seen') {
            final from   = pkt['from']    as String? ?? '';
            final msgIds = (pkt['msg_ids'] as List? ?? []).cast<String>();
            if (from.isEmpty || msgIds.isEmpty) return;
            _seenCtrl.add(LocalSeenEvent(fromUsername: from, msgIds: msgIds));
          }
        } catch (_) { socket.destroy(); }
      });
    } catch (_) {}
  }

  @override
  Future<bool> isCurrentlyAvailable() async {
    if (!_running) return false;
    final ip = await _localIp();
    return ip.isNotEmpty && ip != '192.168.1.1'; // fallback-заглушка _localIp
  }

  // ── Outgoing discover broadcast ───────────────────────────────────────────

  @override
  Future<void> discover() async {
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0,
          reuseAddress: true);
      sock.broadcastEnabled = true;

      final myIp  = await _localIp();
      final bcast = _broadcastAddr(myIp);
      final devId = await AuthService.deviceId();
      final idFields = await signedIdentityFields();

      final pkt = utf8.encode(jsonEncode({
        'type':      'discover',
        'device_id': devId,
        ...idFields,
      }));

      // 1) Broadcast на .255
      sock.send(pkt, InternetAddress(bcast), 47777);
      appLog.info('lan', '→ discover broadcast на $bcast:47777 (я=$myIp, device=$devId)');

      // 2) Unicast на каждый IP в подсети (0-254) — работает между разными подсетями на одном роутере.
      // 255 send() подряд в одном синхронном цикле блокировали кадр отрисовки
      // (юзер репортил лаги UI при любом LAN-действии) — send() сам по себе
      // неблокирующий, но плотный цикл без единой паузы всё равно не даёт
      // Flutter отрисовать кадр между вызовами. Отдаём event loop каждые 32
      // отправки — 255/32 ≈ 8 коротких пауз, коммит всё равно укладывается
      // в доли секунды, а кадры больше не проседают.
      final prefix = myIp.split('.').take(3).join('.');
      var sent = 0;
      for (var i = 0; i <= 254; i++) {
        final target = '$prefix.$i';
        if (target == myIp) continue;
        sock.send(pkt, InternetAddress(target), 47777);
        sent++;
        if (sent % 32 == 0) await Future.delayed(Duration.zero);
      }
      appLog.info('lan', '→ discover unicast $prefix.0-254 (255 адресов)');
    } catch (e) {
      appLog.error('lan', 'discover ошибка: $e');
    } finally {
      sock?.close();
    }
  }

  // ── Send TCP accept ───────────────────────────────────────────────────────

  @override
  Future<void> sendAccept(LocalPeer peer) async {
    try {
      final devId = await AuthService.deviceId();
      final idFields = await signedIdentityFields();
      await _sendTcp(peer.address, jsonEncode({
        'type':      'accept',
        'device_id': devId,
        ...idFields,
      }));
      appLog.info('lan', '→ accept на ${peer.address} (device=$devId)');

      if (peer.x25519PubB64.isNotEmpty) {
        try {
          storeSession(peer.deviceId, peer.address, base64.decode(peer.x25519PubB64));
        } catch (_) {}
      }
    } catch (_) {}
  }

  // ── Send message ──────────────────────────────────────────────────────────

  @override
  Future<void> sendMessage(
    String toUsername,
    String msgId,
    String encB64,
    int    sentAt, {
    String replyToMsgId = '',
  }) async {
    final ip = getPeerIp(toUsername);
    if (ip == null) return;
    await _sendTcp(ip, jsonEncode({
      'type':    'message',
      'from':    _myDeviceId ?? '',
      'msg_id':  msgId,
      'enc_body': encB64,
      'sent_at': sentAt,
      if (replyToMsgId.isNotEmpty) 'reply_to_msg_id': replyToMsgId,
    }));
  }

  // ── Send seen ─────────────────────────────────────────────────────────────

  @override
  Future<void> sendSeen(String toUsername, List<String> msgIds) async {
    if (msgIds.isEmpty) return;
    final ip = getPeerIp(toUsername);
    if (ip == null) return;
    await _sendTcp(ip, jsonEncode({
      'type':    'seen',
      'from':    _myDeviceId ?? '',
      'msg_ids': msgIds,
    }));
  }

  // ── TCP helper ────────────────────────────────────────────────────────────

  Future<void> _sendTcp(String ip, String json) async {
    try {
      final sock = await Socket.connect(ip, 47778,
          timeout: const Duration(seconds: 3));
      sock.write(json);
      await sock.flush();
      sock.destroy();
    } catch (_) {}
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<String> _localIp() async {
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      // 1) Приоритет WiFi интерфейсу (wlan0)
      for (final iface in ifaces) {
        if (iface.name.toLowerCase().startsWith('wlan')) {
          for (final addr in iface.addresses) {
            if (!addr.isLoopback) {
              appLog.debug('lan', 'WiFi IP: ${addr.address} (${iface.name})');
              return addr.address;
            }
          }
        }
      }
      // 2) Приоритет 192.168.x.x / 172.16-31.x.x (локальные сети)
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            final ip = addr.address;
            if (ip.startsWith('192.168.') || ip.startsWith('172.')) {
              appLog.debug('lan', 'Локальный IP: $ip (${iface.name})');
              return ip;
            }
          }
        }
      }
      // 3) Любой не-loopback
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            appLog.warn('lan', 'Fallback IP: ${addr.address} (${iface.name}) — возможно мобильная сеть');
            return addr.address;
          }
        }
      }
    } catch (e) {
      appLog.error('lan', '_localIp ошибка: $e');
    }
    return '192.168.1.1';
  }

  String _broadcastAddr(String ip) {
    final parts = ip.split('.');
    return '${parts[0]}.${parts[1]}.${parts[2]}.255';
  }
}
