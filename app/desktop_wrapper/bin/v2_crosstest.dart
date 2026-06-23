// Кросс-тест v2-крипты: проверяем, что Dart (пакет cryptography) даёт те же
// байты, что web (nacl/WebCrypto) и python (cryptography). Эталон — известные
// значения claude_helper из ~/.claude_chat/state.json.
//   dart run bin/v2_crosstest.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

final _ed = Ed25519();
final _x = X25519();

Future<Uint8List> hkdf(List<int> ikm, String info) async {
  final h = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final k = await h.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: Uint8List(32), // salt = 32 нулей
    info: utf8.encode(info),
  );
  return Uint8List.fromList(await k.extractBytes());
}

Future<Uint8List> mnemonicToSeed(String m) async {
  final p = Pbkdf2(macAlgorithm: Hmac.sha512(), iterations: 2048, bits: 512);
  final k = await p.deriveKey(
    secretKey: SecretKey(utf8.encode(m.trim().toLowerCase())),
    nonce: utf8.encode('mnemonicghostchat-v2'),
  );
  return Uint8List.fromList(await k.extractBytes());
}

Future<List<Uint8List>> seedToIdentity(Uint8List seed64) async {
  final seed32 = await hkdf(seed64, 'ghostchat-v2-identity');
  final kp = await _ed.newKeyPairFromSeed(seed32);
  final pub = await kp.extractPublicKey();
  return [seed32, Uint8List.fromList(pub.bytes)];
}

Future<String> encryptV2(Uint8List devPub, List<int> pt) async {
  final eph = await _x.newKeyPair();
  final ephPub = await eph.extractPublicKey();
  final sh = await _x.sharedSecretKey(
    keyPair: eph,
    remotePublicKey: SimplePublicKey(devPub, type: KeyPairType.x25519),
  );
  final aes = SecretKey(await hkdf(await sh.extractBytes(), 'ghostchat-v2-msg'));
  final gcm = AesGcm.with256bits();
  final iv = gcm.newNonce();
  final box = await gcm.encrypt(pt, secretKey: aes, nonce: iv);
  final out = BytesBuilder()
    ..add(ephPub.bytes)
    ..add(iv)
    ..add(box.cipherText)
    ..add(box.mac.bytes);
  return base64.encode(out.toBytes());
}

Future<String?> decryptV2(Uint8List devPriv, String envB64) async {
  final raw = base64.decode(envB64);
  final ephPub = raw.sublist(0, 32);
  final iv = raw.sublist(32, 44);
  final ctTag = raw.sublist(44);
  final ct = ctTag.sublist(0, ctTag.length - 16);
  final tag = ctTag.sublist(ctTag.length - 16);
  final kp = await _x.newKeyPairFromSeed(devPriv);
  final sh = await _x.sharedSecretKey(
    keyPair: kp,
    remotePublicKey: SimplePublicKey(
      Uint8List.fromList(ephPub),
      type: KeyPairType.x25519,
    ),
  );
  final aes = SecretKey(await hkdf(await sh.extractBytes(), 'ghostchat-v2-msg'));
  final gcm = AesGcm.with256bits();
  try {
    final clear = await gcm.decrypt(
      SecretBox(ct, nonce: iv, mac: Mac(tag)),
      secretKey: aes,
    );
    return utf8.decode(clear);
  } catch (e) {
    return 'DECRYPT FAIL: $e';
  }
}

void main(List<String> args) async {
  const mnemonic =
      'myth marriage sunny bless bunker asthma canoe cradle rail hamster search weasel';
  const expectedPub = 'qsP67DMD6kemt/ZAihDhKJoSe4SVvk5MMcCC0kAs2vk=';
  const expectedSeed = 'qIiXSlTU/MuKiP7XRQtkv+7FePspy6rKVP15IB7CFCw=';

  final seed64 = await mnemonicToSeed(mnemonic);
  final res = await seedToIdentity(seed64);
  final seed32 = res[0], pub = res[1];
  print('identity_pub:   ${base64.encode(pub)}');
  print('expected_pub:   $expectedPub');
  print('seed32:         ${base64.encode(seed32)}');
  print('expected_seed:  $expectedSeed');
  final idOk = base64.encode(pub) == expectedPub && base64.encode(seed32) == expectedSeed;
  print('=> IDENTITY MATCH: $idOk');

  // Шифруем для device_pub claude_helper, дешифруем его device_priv.
  final devPub = Uint8List.fromList(
    base64.decode('O6q1LVWH2zjd4tuHQpPepoQrr5Yoh6HBAAanLG7s0EQ='),
  );
  final devPriv = Uint8List.fromList(
    base64.decode('uBqk2xZ37xtJovgAq0IgTGDrK1TUOjV7y9zchNryf0g='),
  );
  final env = await encryptV2(devPub, utf8.encode('привет v2 from dart'));
  print('envelope:       $env');
  final dec = await decryptV2(devPriv, env);
  print('=> ROUNDTRIP:    $dec');

  // Если python положит свой envelope в args[0] — расшифруем (interop).
  if (args.isNotEmpty) {
    print('=> PY ENVELOPE:  ${await decryptV2(devPriv, args[0])}');
  }
}
