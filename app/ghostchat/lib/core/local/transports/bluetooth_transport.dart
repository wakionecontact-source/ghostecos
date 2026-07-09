import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../app_logger.dart';
import '../local_transport.dart';
import '../lan_identity.dart';
import '../../../services/auth_service.dart';
import '../../../services/crypto_v2.dart';

// Native BLE peripheral (GATT server + advertising)
const _peripheralChannel = MethodChannel('ghostchat/ble_peripheral');
const _peripheralEvents  = EventChannel('ghostchat/ble_peripheral/events');

// GhostChat BLE service and characteristic UUIDs
const _serviceUuid     = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';
const _discoveryUuid   = 'a1b2c3d4-e5f6-7890-abcd-ef1234567891';
const _messageUuid     = 'a1b2c3d4-e5f6-7890-abcd-ef1234567892';

class _BtSession {
  final String address;
  final List<int> key;
  BluetoothDevice? device;
  BluetoothCharacteristic? msgChar;
  _BtSession({required this.address, required this.key, this.device, this.msgChar});
}

class BluetoothTransport implements LocalTransport {
  @override
  TransportType get type => TransportType.bluetooth;

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
  bool _scanning = false; // prevent overlapping scans
  String? _myDeviceId;
  StreamSubscription? _scanSub;
  StreamSubscription? _peripheralSub;
  final Map<String, _BtSession> _sessions = {};
  final Set<String> _blockedDeviceIds = {};
  final Set<String> _blockedAddresses = {};
  final Set<String> _knownDevices = {}; // remoteIds already seen across scans

  @override List<int>? getKey(String username) => _sessions[username]?.key;
  @override bool hasSession(String username) => _sessions.containsKey(username);

  @override
  void storeSession(String username, String address, List<int> key) {
    _sessions[username] = _BtSession(address: address, key: key);
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
    appLog.info('bt', 'BLE запускается');
    _myDeviceId = await AuthService.deviceId();
    await CryptoV2.instance.ensureKeys();

    // Start BLE peripheral (GATT server + advertising) so other devices can find us
    try {
      final idFields = await signedIdentityFields();
      final discoveryJson = jsonEncode({
        'device_id': _myDeviceId,
        ...idFields,
      });
      await _peripheralChannel.invokeMethod('start', {'discoveryJson': discoveryJson});
      appLog.info('bt', 'BLE peripheral запущен');
    } catch (e) {
      appLog.error('bt', 'BLE peripheral ошибка: $e');
    }

    // Listen for incoming data from peripheral (other devices writing to us)
    _peripheralSub?.cancel();
    _peripheralSub = _peripheralEvents.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        final data = Map<String, dynamic>.from(event);
        final eventType = data['event'] as String? ?? '';
        if (eventType == 'data_received') {
          final json = data['json'] as String? ?? '';
          final address = data['address'] as String? ?? '';
          if (json.isNotEmpty) _handlePeripheralData(address, json);
        }
      }
    });
  }

  Future<void> _handlePeripheralData(String address, String jsonStr) async {
    try {
      final pkt = jsonDecode(jsonStr) as Map<String, dynamic>;
      final type = pkt['type'] as String? ?? '';
      final from = pkt['from'] as String? ?? '';
      appLog.debug('bt', 'peripheral ← $type от $from ($address)');

      if (type == 'message') {
        final msgId  = pkt['msg_id']   as String? ?? '';
        final encB64 = pkt['enc_body'] as String? ?? '';
        final sentAt = (pkt['sent_at'] as num?)?.toInt() ?? 0;
        final replyTo = pkt['reply_to_msg_id'] as String? ?? '';
        if (from.isEmpty || msgId.isEmpty) return;

        // Auto-ack via peripheral
        try {
          _peripheralChannel.invokeMethod('sendToDevice', {
            'address': address,
            'json': jsonEncode({'type': 'ack', 'from': _myDeviceId ?? '', 'msg_id': msgId}),
          });
        } catch (_) {}

        _msgCtrl.add(LocalMessageEvent(
          fromUsername: from, msgId: msgId,
          encB64: encB64, sentAt: sentAt,
          replyToMsgId: replyTo, transport: TransportType.bluetooth,
        ));
      } else if (type == 'ack') {
        final msgId = pkt['msg_id'] as String? ?? '';
        if (msgId.isNotEmpty) {
          _ackCtrl.add(LocalAckEvent(fromUsername: from, msgId: msgId));
        }
      } else if (type == 'seen') {
        final msgIds = (pkt['msg_ids'] as List? ?? []).cast<String>();
        if (msgIds.isNotEmpty) {
          _seenCtrl.add(LocalSeenEvent(fromUsername: from, msgIds: msgIds));
        }
      } else if (type == 'discover') {
        final deviceId = pkt['device_id'] as String? ?? '';
        final peerX25519Pub = pkt['x25519_pub'] as String? ?? '';
        final identityPub = pkt['identity_pub'] as String? ?? '';
        final sig = pkt['signed_prekey_sig'] as String? ?? '';
        appLog.info('bt', '← peripheral discover device=$deviceId');
        if (deviceId.isNotEmpty && !isBlocked(deviceId, address)) {
          final verified = await verifyPeerIdentity(
            x25519PubB64: peerX25519Pub,
            identityPubB64: identityPub,
            signedPrekeySigB64: sig,
          );
          if (!verified) return;
          _requestCtrl.add(LocalPeer(
            peerId:       '$deviceId@bt:$address',
            deviceId:     deviceId,
            x25519PubB64: peerX25519Pub,
            identityPubB64: identityPub,
            signedPrekeySigB64: sig,
            transport:    TransportType.bluetooth,
            address:      address,
          ));
        }
      }
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    _running = false;
    _scanning = false;
    _scanSub?.cancel();
    _peripheralSub?.cancel();
    try { await _peripheralChannel.invokeMethod('stop'); } catch (_) {}
    await FlutterBluePlus.stopScan();
    for (final s in _sessions.values) {
      s.device?.disconnect();
    }
    _sessions.clear();
    _knownDevices.clear();
  }

  @override
  Future<bool> isCurrentlyAvailable() async {
    if (!_running) return false;
    try {
      return await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> discover() async {
    if (!_running) return;
    // Don't restart scan if already scanning — called every 3s by timer
    if (_scanning) {
      appLog.debug('bt', 'BLE scan уже идёт, пропускаем');
      return;
    }

    try {
      final isOn = await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on;
      if (!isOn) {
        appLog.warn('bt', 'Bluetooth выключен');
        return;
      }
    } catch (e) {
      appLog.error('bt', 'Проверка BT адаптера: $e');
      return;
    }

    _scanning = true;
    appLog.info('bt', '→ BLE scan запускается');

    // Don't clear _knownDevices — keep them across scans to avoid re-connecting
    _scanSub?.cancel();

    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final remoteId = r.device.remoteId.str;
        if (_knownDevices.contains(remoteId)) continue;
        if (isBlocked('', remoteId)) continue;

        // Check if this device advertises our service
        final hasService = r.advertisementData.serviceUuids
            .any((u) => u.str.toLowerCase() == _serviceUuid);
        if (!hasService) continue;

        _knownDevices.add(remoteId);
        appLog.info('bt', '← найдено BLE устройство: ${r.device.platformName} ($remoteId)');
        _connectAndDiscover(r.device);
      }
    });

    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(_serviceUuid)],
        timeout: const Duration(seconds: 15),
      );
    } finally {
      _scanning = false;
    }
  }

  Future<void> _connectAndDiscover(BluetoothDevice device) async {
    try {
      await device.connect(timeout: const Duration(seconds: 8));
      final services = await device.discoverServices();

      BluetoothService? gcService;
      for (final s in services) {
        if (s.uuid.str.toLowerCase() == _serviceUuid) {
          gcService = s;
          break;
        }
      }
      if (gcService == null) { device.disconnect(); return; }

      // Read discovery characteristic
      BluetoothCharacteristic? discChar;
      BluetoothCharacteristic? msgChar;
      for (final c in gcService.characteristics) {
        if (c.uuid.str.toLowerCase() == _discoveryUuid) discChar = c;
        if (c.uuid.str.toLowerCase() == _messageUuid)   msgChar = c;
      }

      if (discChar == null || msgChar == null) { device.disconnect(); return; }

      final discBytes = await discChar.read();
      if (discBytes.isEmpty) { device.disconnect(); return; }

      final discData = jsonDecode(utf8.decode(discBytes)) as Map<String, dynamic>;
      final deviceId = discData['device_id'] as String? ?? '';
      final peerX25519Pub = discData['x25519_pub'] as String? ?? '';
      final identityPub = discData['identity_pub'] as String? ?? '';
      final sig = discData['signed_prekey_sig'] as String? ?? '';

      if (deviceId.isEmpty) {
        device.disconnect();
        return;
      }
      if (isBlocked(deviceId, device.remoteId.str)) {
        appLog.debug('bt', 'Заблокирован: $deviceId');
        device.disconnect();
        return;
      }
      final verified = await verifyPeerIdentity(
        x25519PubB64: peerX25519Pub,
        identityPubB64: identityPub,
        signedPrekeySigB64: sig,
      );
      if (!verified) {
        device.disconnect();
        return;
      }

      appLog.info('bt', '← discover device=$deviceId через BLE');
      _requestCtrl.add(LocalPeer(
        peerId:       '$deviceId@bt:${device.remoteId.str}',
        deviceId:     deviceId,
        x25519PubB64: peerX25519Pub,
        identityPubB64: identityPub,
        signedPrekeySigB64: sig,
        transport:    TransportType.bluetooth,
        address:      device.remoteId.str,
      ));

      // Keep device reference for later (keyed by deviceId until we learn username)
      _sessions[deviceId] = _BtSession(
        address: device.remoteId.str,
        key: [], // key will be derived on accept
        device: device,
        msgChar: msgChar,
      );

      // Subscribe to notifications from message characteristic
      await msgChar.setNotifyValue(true);
      msgChar.onValueReceived.listen((bytes) {
        _handleIncoming(deviceId, bytes);
      });

    } catch (_) {
      try { device.disconnect(); } catch (_) {}
    }
  }

  void _handleIncoming(String fromDeviceId, List<int> bytes) {
    try {
      final pkt = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final type = pkt['type'] as String? ?? '';
      final from = pkt['from'] as String? ?? fromDeviceId;

      if (type == 'accept') {
        _handleAccept(fromDeviceId, pkt);
      } else if (type == 'message') {
        final msgId  = pkt['msg_id']   as String? ?? '';
        final encB64 = pkt['enc_body'] as String? ?? '';
        final sentAt = (pkt['sent_at'] as num?)?.toInt() ?? 0;
        final replyTo = pkt['reply_to_msg_id'] as String? ?? '';
        if (from.isEmpty || msgId.isEmpty) return;

        // Auto-ack
        _sendToUser(fromDeviceId, jsonEncode({
          'type': 'ack', 'from': _myDeviceId ?? '', 'msg_id': msgId,
        }));

        _msgCtrl.add(LocalMessageEvent(
          fromUsername: from, msgId: msgId,
          encB64: encB64, sentAt: sentAt,
          replyToMsgId: replyTo, transport: TransportType.bluetooth,
        ));
      } else if (type == 'ack') {
        final msgId = pkt['msg_id'] as String? ?? '';
        if (msgId.isNotEmpty) {
          _ackCtrl.add(LocalAckEvent(fromUsername: from, msgId: msgId));
        }
      } else if (type == 'seen') {
        final msgIds = (pkt['msg_ids'] as List? ?? []).cast<String>();
        if (msgIds.isNotEmpty) {
          _seenCtrl.add(LocalSeenEvent(fromUsername: from, msgIds: msgIds));
        }
      }
    } catch (_) {}
  }

  Future<void> _handleAccept(String fromDeviceId, Map<String, dynamic> pkt) async {
    final deviceId  = pkt['device_id']  as String? ?? fromDeviceId;
    final x25519Pub = pkt['x25519_pub'] as String? ?? '';
    final identityPub = pkt['identity_pub'] as String? ?? '';
    final sig = pkt['signed_prekey_sig'] as String? ?? '';
    appLog.info('bt', '← accept device=$deviceId');

    final verified = await verifyPeerIdentity(
      x25519PubB64: x25519Pub,
      identityPubB64: identityPub,
      signedPrekeySigB64: sig,
    );
    if (!verified) return;

    if (x25519Pub.isNotEmpty) {
      try {
        final peerPub = base64.decode(x25519Pub);
        final existing = _sessions[deviceId];
        if (existing != null) {
          _sessions[deviceId] = _BtSession(
            address: existing.address, key: peerPub,
            device: existing.device, msgChar: existing.msgChar,
          );
        }
      } catch (_) {}
    }

    _acceptCtrl.add(LocalPeer(
      peerId:       '$deviceId@bt',
      deviceId:     deviceId,
      x25519PubB64: x25519Pub,
      identityPubB64: identityPub,
      signedPrekeySigB64: sig,
      transport:    TransportType.bluetooth,
      address:      _sessions[deviceId]?.address ?? '',
    ));
  }

  @override
  Future<void> sendAccept(LocalPeer peer) async {
    try {
      final devId = await AuthService.deviceId();
      final idFields = await signedIdentityFields();
      await _sendToUser(peer.deviceId, jsonEncode({
        'type':      'accept',
        'device_id': devId,
        ...idFields,
      }));
      appLog.info('bt', '→ accept device=${peer.deviceId}');

      if (peer.x25519PubB64.isNotEmpty) {
        try {
          final peerPub = base64.decode(peer.x25519PubB64);
          final existing = _sessions[peer.deviceId];
          if (existing != null) {
            _sessions[peer.deviceId] = _BtSession(
              address: existing.address, key: peerPub,
              device: existing.device, msgChar: existing.msgChar,
            );
          } else {
            storeSession(peer.deviceId, peer.address, peerPub);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  Future<void> sendMessage(String toDeviceId, String msgId, String encB64, int sentAt, {String replyToMsgId = ''}) async {
    await _sendToUser(toDeviceId, jsonEncode({
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
    await _sendToUser(toDeviceId, jsonEncode({
      'type':    'seen',
      'from':    _myDeviceId ?? '',
      'msg_ids': msgIds,
    }));
  }

  Future<void> _sendToUser(String username, String json) async {
    final s = _sessions[username];
    if (s == null || s.msgChar == null) return;
    try {
      final bytes = utf8.encode(json);
      // BLE has MTU limit — chunk if needed
      final mtu = s.device?.mtuNow ?? 512;
      final chunkSize = mtu - 3;
      if (bytes.length <= chunkSize) {
        await s.msgChar!.write(bytes, withoutResponse: true);
      } else {
        // Simple chunking: split into pieces
        for (var i = 0; i < bytes.length; i += chunkSize) {
          final end = (i + chunkSize > bytes.length) ? bytes.length : i + chunkSize;
          await s.msgChar!.write(bytes.sublist(i, end), withoutResponse: true);
          await Future.delayed(const Duration(milliseconds: 20));
        }
      }
    } catch (_) {}
  }
}
