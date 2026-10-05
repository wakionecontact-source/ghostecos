import 'dart:convert';
import 'dart:typed_data';

/// Domain-separated byte encodings shared by mobile, web, and server clients.
abstract final class ChatMessageAuth {
  static Uint8List? tryDecodeBase64(String value) {
    try {
      return Uint8List.fromList(base64.decode(value));
    } catch (_) {
      return null;
    }
  }

  static Uint8List v2EnvelopeBytes({
    required String senderIdentityPub,
    required String toUsername,
    required int targetDeviceId,
    required String envelope,
  }) => _nulSeparated('ghostchat-v2-envelope-v1', [
    senderIdentityPub,
    toUsername.trim().toLowerCase(),
    '$targetDeviceId',
    envelope,
  ]);

  static Uint8List sealedEnvelopeBytes({
    required String senderIdentityPub,
    required String toUsername,
    required String ciphertext,
  }) => _nulSeparated('ghostchat-sealed-envelope-v1', [
    senderIdentityPub,
    toUsername.trim().toLowerCase(),
    ciphertext,
  ]);

  /// Canonical compact JSON for P2P packets; map keys are sorted recursively.
  static Uint8List p2pPayloadBytes(Map<String, dynamic> payload) =>
      Uint8List.fromList(utf8.encode(jsonEncode(_canonicalize(payload))));

  static Uint8List _nulSeparated(String domain, List<String> fields) =>
      Uint8List.fromList(utf8.encode('$domain\u0000${fields.join('\u0000')}'));

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: _canonicalize(value[key]),
      };
    }
    if (value is List) return value.map(_canonicalize).toList();
    return value;
  }
}
