// Общая для всех транспортов (LAN/BLE/Wi-Fi Direct) логика подписи и
// проверки device-ключа Ed25519-идентичностью — тот же принцип, что и на
// сервере (CryptoV2.verifySignedPrekey), чтобы device-ключ нельзя было
// подменить на лету в локальной сети без владения identity-приватником.
import 'dart:convert';
import '../../services/crypto_v2.dart';
import 'app_logger.dart';

/// Поля, которые нужно добавить в discover/accept-пакет для доказательства
/// владения x25519-ключом устройства.
Future<Map<String, String>> signedIdentityFields() async {
  final sig = await CryptoV2.instance.signedPrekeySig();
  return {
    'x25519_pub': CryptoV2.instance.devicePubB64,
    'identity_pub': CryptoV2.instance.identityPubB64,
    'signed_prekey_sig': base64Encode(sig),
  };
}

/// Проверить, что x25519_pub из входящего пакета реально подписан
/// identity_pub тем же пиром. false → пакет нужно молча отбросить.
Future<bool> verifyPeerIdentity({
  required String x25519PubB64,
  required String identityPubB64,
  required String signedPrekeySigB64,
}) async {
  if (x25519PubB64.isEmpty || identityPubB64.isEmpty || signedPrekeySigB64.isEmpty) {
    appLog.warn('security', 'LAN-пакет без подписи identity — отброшен');
    return false;
  }
  try {
    final ok = await CryptoV2.instance.verifySignedPrekey(
      identityPub: base64Decode(identityPubB64),
      devicePub: base64Decode(x25519PubB64),
      signature: base64Decode(signedPrekeySigB64),
    );
    if (!ok) appLog.warn('security', 'LAN-пакет: подпись identity НЕ совпала — отброшен');
    return ok;
  } catch (e) {
    appLog.warn('security', 'LAN-пакет: ошибка проверки подписи: $e');
    return false;
  }
}
