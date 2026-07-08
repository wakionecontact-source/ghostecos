import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import '../app_logger.dart';
import '../local_transport.dart';
import '../../../services/auth_service.dart';
import '../../../services/crypto_v2.dart';

class _WdSession {
  final String address;
  final List<int> key;
  _WdSession({required this.address, required this.key});
}

class WifiDirectTransport implements LocalTransport {
  @override
  TransportType get type => TransportType.wifiDirect;

  static const _channel = MethodChannel('ghostchat/wifi_direct');
  static const _events  = EventChannel('ghostchat/wifi_direct/events');

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

  bool _running = false;
  String? _myDeviceId;
  StreamSubscription? _eventSub;

  final Map<String, _WdSession> _sessions = {};
  final Map<String, String> _deviceToUsername = {};
  final Map<String, String> _usernameToDevice = {};
  final Set<String> _blockedDeviceIds = {};
  final Set<String> _blockedAddresses = {};

  @override List<int>? getKey(String username) => _sessions[username]?.key;
  @override bool hasSession(String username) => _sessions.containsKey(username);

  @override
  void storeSession(String username, String address, List<int> key) {
    _sessions[username] = _WdSession(address: address, key: key);
  }

  @override
  void blockPeer(String deviceId, String address) {
    if (deviceId.isNotEmpty)  _blockedDeviceIds.add(deviceId);
    if (address.isNotEmpty)   _blockedAddresses.add(address);
  }

  @override
  bool isBlocked(String deviceId, String address) =>
      _blockedDeviceIds.contains(deviceId) || _blockedAddresses.contains(address);

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    appLog.info('wifi_direct', 'WiFi Direct запускается');
    _myDeviceId = await AuthService.deviceId();
    await CryptoV2.instance.ensureKeys();

    try {
      await _channel.invokeMethod('init', {
        'serviceName': 'ghostchat',
        'displayName': 'ghost',
      });
      appLog.info('wifi_direct', 'WiFi Direct init OK');
    } on MissingPluginException {
      appLog.error('wifi_direct', 'MissingPluginException — плагин не зарегистрирован');
      _running = false;
      return;
    }

    _eventSub = _events.receiveBroadcastStream().listen((event) {
      if (event is Map) _handleEvent(Map<String, dynamic>.from(event));
    });
  }

  @override
  Future<void> stop() async {
    _running = false;
    _eventSub?.cancel();
    try { await _channel.invokeMethod('stop'); } catch (_) {}
    _sessions.clear();
    _deviceToUsername.clear();
    _usernameToDevice.clear();
  }

  @override
  Future<void> discover() async {
    if (!_running) return;
    appLog.info('wifi_direct', '→ WiFi Direct discover');
    try {
      await _channel.invokeMethod('discover');
    } catch (e) {
      appLog.error('wifi_direct', 'discover ошибка: $e');
    }
  }

  String? _groupOwnerAddress;
  bool _isGroupOwner = false;
  final Set<String> _discoveredAddresses = {};

  void _handleEvent(Map<String, dynamic> event) {
    final eventType = event['event'] as String? ?? '';
    appLog.debug('wifi_direct', 'event: $eventType');

    if (eventType == 'peer_found') {
      final deviceAddress = event['deviceAddress'] as String? ?? '';
      final status = event['status'] as int? ?? -1;
      // status 3 = available
      if (deviceAddress.isNotEmpty && status == 3 && !_discoveredAddresses.contains(deviceAddress)) {
        _discoveredAddresses.add(deviceAddress);
        // Auto-connect to discovered peer
        try { _channel.invokeMethod('connect', {'deviceAddress': deviceAddress}); } catch (_) {}
      }
    } else if (eventType == 'connected') {
      _isGroupOwner = event['isGroupOwner'] as bool? ?? false;
      _groupOwnerAddress = event['groupOwnerAddress'] as String? ?? '';
      // Send discover packet to the group owner (or wait for client to connect)
      final targetAddr = _isGroupOwner ? '' : (_groupOwnerAddress ?? '');
      if (targetAddr.isNotEmpty) {
        _sendDiscoverPacket(targetAddr);
      }
    } else if (eventType == 'data_received') {
      final json = event['json'] as String? ?? '';
      final fromAddress = event['fromAddress'] as String? ?? '';
      if (json.isNotEmpty) _handleData(fromAddress, json);
    }
  }

  Future<void> _sendDiscoverPacket(String peerId) async {
    final devId = await AuthService.deviceId();
    _sendToPeer(peerId, jsonEncode({
      'type':      'discover',
      'device_id': devId,
      'x25519_pub': CryptoV2.instance.devicePubB64,
    }));
  }

  Future<void> _sendToPeer(String address, String message) async {
    try {
      await _channel.invokeMethod('send', {
        'address': address,
        'json': message,
      });
    } catch (_) {}
  }

  void _handleData(String peerId, String message) {
    try {
      final pkt = jsonDecode(message) as Map<String, dynamic>;
      final type = pkt['type'] as String? ?? '';
      if (type == 'discover') {
        final peerDeviceId = pkt['device_id'] as String? ?? '';
        if (peerDeviceId.isEmpty) return;
        if (isBlocked(peerDeviceId, peerId)) return;
        final peerX25519Pub = pkt['x25519_pub'] as String? ?? '';

        _requestCtrl.add(LocalPeer(
          peerId:       '$peerDeviceId@wd:$peerId',
          deviceId:     peerDeviceId,
          x25519PubB64: peerX25519Pub,
          transport:    TransportType.wifiDirect,
          address:      peerId,
        ));
      } else if (type == 'accept') {
        _handleAcceptPkt(pkt, peerId);
      } else if (type == 'message') {
        final from   = pkt['from']       as String? ?? '';
        final msgId  = pkt['msg_id']     as String? ?? '';
        final encB64 = pkt['enc_body']   as String? ?? '';
        final sentAt = (pkt['sent_at'] as num?)?.toInt() ?? 0;
        final replyTo = pkt['reply_to_msg_id'] as String? ?? '';
        if (from.isEmpty || msgId.isEmpty) return;

        final nearbyId = _usernameToDevice[from] ?? peerId;
        _sendToPeer(nearbyId, jsonEncode({
          'type': 'ack', 'from': _myDeviceId ?? '', 'msg_id': msgId,
        }));

        _msgCtrl.add(LocalMessageEvent(
          fromUsername: from, msgId: msgId, encB64: encB64,
          sentAt: sentAt, replyToMsgId: replyTo,
          transport: TransportType.wifiDirect,
        ));
      } else if (type == 'ack') {
        final from  = pkt['from']   as String? ?? '';
        final msgId = pkt['msg_id'] as String? ?? '';
        if (from.isNotEmpty && msgId.isNotEmpty) {
          _ackCtrl.add(LocalAckEvent(fromUsername: from, msgId: msgId));
        }
      } else if (type == 'seen') {
        final from   = pkt['from']    as String? ?? '';
        final msgIds = (pkt['msg_ids'] as List? ?? []).cast<String>();
        if (from.isNotEmpty && msgIds.isNotEmpty) {
          _seenCtrl.add(LocalSeenEvent(fromUsername: from, msgIds: msgIds));
        }
      }
    } catch (_) {}
  }

  Future<void> _handleAcceptPkt(Map<String, dynamic> pkt, String peerId) async {
    final deviceId  = pkt['device_id']  as String? ?? '';
    final x25519Pub = pkt['x25519_pub'] as String? ?? '';
    if (deviceId.isEmpty) return;
    appLog.info('wifi_direct', '← accept device=$deviceId');

    _deviceToUsername[peerId] = deviceId;
    _usernameToDevice[deviceId] = peerId;

    if (x25519Pub.isNotEmpty) {
      try {
        storeSession(deviceId, peerId, base64.decode(x25519Pub));
      } catch (_) {}
    }

    _acceptCtrl.add(LocalPeer(
      peerId:       '$deviceId@wd',
      deviceId:     deviceId,
      x25519PubB64: x25519Pub,
      transport:    TransportType.wifiDirect,
      address:      peerId,
    ));
  }

  @override
  Future<void> sendAccept(LocalPeer peer) async {
    final nearbyId = _usernameToDevice[peer.deviceId] ?? peer.address;
    try {
      final x25519b64 = CryptoV2.instance.devicePubB64;
      final devId = await AuthService.deviceId();
      _sendToPeer(nearbyId, jsonEncode({
        'type':      'accept',
        'device_id': devId,
        'x25519_pub': x25519b64,
      }));
      appLog.info('wifi_direct', '→ accept device=${peer.deviceId}');

      if (peer.x25519PubB64.isNotEmpty) {
        try {
          storeSession(peer.deviceId, nearbyId, base64.decode(peer.x25519PubB64));
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  Future<void> sendMessage(String toDeviceId, String msgId, String encB64, int sentAt, {String replyToMsgId = ''}) async {
    final nearbyId = _usernameToDevice[toDeviceId];
    if (nearbyId == null) return;
    _sendToPeer(nearbyId, jsonEncode({
      'type':    'message',
      'from':    _myDeviceId ?? '',
      'msg_id':  msgId,
      'enc_body': encB64,
      'sent_at': sentAt,
      if (replyToMsgId.isNotEmpty) 'reply_to_msg_id': replyToMsgId,
    }));
  }

  @override
  Future<void> sendSeen(String toDeviceId, List<String> msgIds) async {
    if (msgIds.isEmpty) return;
    final nearbyId = _usernameToDevice[toDeviceId];
    if (nearbyId == null) return;
    _sendToPeer(nearbyId, jsonEncode({
      'type':    'seen',
      'from':    _myDeviceId ?? '',
      'msg_ids': msgIds,
    }));
  }
}
