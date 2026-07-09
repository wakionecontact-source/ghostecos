import 'dart:async';

// ── Transport types ──────────────────────────────────────────────────────────

enum TransportType { lan, wifiDirect, bluetooth }

String transportLabel(TransportType t) {
  switch (t) {
    case TransportType.lan:        return 'LAN';
    case TransportType.wifiDirect: return 'Wi-Fi Direct';
    case TransportType.bluetooth:  return 'Bluetooth';
  }
}

// ── Shared event classes ─────────────────────────────────────────────────────

class LocalPeer {
  final String peerId;
  final String username;
  final String displayName;
  final String about;
  final String x25519PubB64;
  // Ed25519-идентичность пира (CryptoV2) + подпись identity-ключом над
  // x25519PubB64 — доказывает, что device-ключ реально принадлежит этой
  // идентичности (не может быть подменён на лету MITM-ом в локальной сети).
  final String identityPubB64;
  final String signedPrekeySigB64;
  final String deviceId;
  final TransportType transport;
  final String address; // IP for LAN, device address for BT, endpoint for WiFi Direct
  const LocalPeer({
    required this.peerId,
    this.username = '',
    this.displayName = '',
    this.about = '',
    this.x25519PubB64 = '',
    this.identityPubB64 = '',
    this.signedPrekeySigB64 = '',
    this.deviceId = '',
    required this.transport,
    required this.address,
  });

  /// Короткая подпись для UI/имени чата, когда displayName неизвестен —
  /// первые 8 символов device_id.
  String get label => deviceId.length > 8 ? '${deviceId.substring(0, 8)}…' : deviceId;

  String get chatType {
    switch (transport) {
      case TransportType.lan:        return 'lan';
      case TransportType.wifiDirect: return 'wifi_direct';
      case TransportType.bluetooth:  return 'bluetooth';
    }
  }
}

class LocalMessageEvent {
  final String fromUsername;
  final String msgId;
  final String encB64;
  final int    sentAt;
  final String replyToMsgId;
  final TransportType transport;
  const LocalMessageEvent({
    required this.fromUsername,
    required this.msgId,
    required this.encB64,
    required this.sentAt,
    this.replyToMsgId = '',
    required this.transport,
  });
}

class LocalAckEvent {
  final String fromUsername;
  final String msgId;
  const LocalAckEvent({required this.fromUsername, required this.msgId});
}

class LocalSeenEvent {
  final String fromUsername;
  final List<String> msgIds;
  const LocalSeenEvent({required this.fromUsername, required this.msgIds});
}

// ── Abstract transport ───────────────────────────────────────────────────────

abstract class LocalTransport {
  TransportType get type;

  Stream<LocalPeer>         get onRequest;
  Stream<LocalPeer>         get onAccept;
  Stream<LocalMessageEvent> get onMessage;
  Stream<LocalAckEvent>     get onAck;
  Stream<LocalSeenEvent>    get onSeen;

  Future<void> start();
  Future<void> stop();
  Future<void> discover();
  /// Живая проверка "работает ли этот способ связи ПРЯМО СЕЙЧАС" (не просто
  /// "транспорт запущен при старте приложения") — например, Bluetooth могли
  /// выключить в шторке уже после запуска. Используется для отчёта в
  /// __ping__/__pong__, чтобы собеседник знал, каким способом сейчас реально
  /// можно достучаться.
  Future<bool> isCurrentlyAvailable();
  Future<void> sendAccept(LocalPeer peer);
  Future<void> sendMessage(String toUsername, String msgId, String encB64, int sentAt, {String replyToMsgId = ''});
  Future<void> sendSeen(String toUsername, List<String> msgIds);
  bool hasSession(String username);
  List<int>? getKey(String username);
  void storeSession(String username, String address, List<int> key);
  void blockPeer(String deviceId, String address);
  bool isBlocked(String deviceId, String address);
}
