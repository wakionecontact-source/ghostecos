// GhostChat Keys v2 — клиентская крипта (Dart). Зеркало server/chat/keys_v2.js
// и ~/.claude_chat/claude_chat_v2.py. Кросс-протестировано: Ed25519 (RFC 8032)
// совпадает с python/nacl, X25519+HKDF+AES-GCM интероп подтверждён (python
// расшифровал Dart-envelope).
//
//   Identity : Ed25519 из BIP-39 seed (PBKDF2-SHA512 → HKDF → seed32).
//   Device   : X25519 (на каждое устройство свой).
//   Сообщение: эфемерная X25519-пара → ECDH(eph_priv, peer_dev_pub) →
//              HKDF-SHA256(salt=0, info='ghostchat-v2-msg') → AES-256-GCM.
//              envelope = eph_pub(32) || iv(12) || ct || tag(16), base64.
//
// Ключи лежат в flutter_secure_storage. seed-фраза = бэкап для восстановления.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CryptoV2 {
  CryptoV2._();
  static final CryptoV2 instance = CryptoV2._();

  final _ed = Ed25519();
  final _x = X25519();
  final _ss = const FlutterSecureStorage();

  static const _kSeed = 'v2_identity_seed32';
  static const _kIdPub = 'v2_identity_pub';
  static const _kDevPriv = 'v2_device_priv';
  static const _kDevPub = 'v2_device_pub';
  static const _kMnemonic = 'v2_mnemonic';

  List<String>? _wl;
  Uint8List? _seed32, _idPub, _devPriv, _devPub;

  bool get ready => _seed32 != null && _devPriv != null;
  Uint8List get identityPub => _idPub!;
  Uint8List get devicePub => _devPub!;
  String get identityPubB64 => base64.encode(_idPub!);
  String get devicePubB64 => base64.encode(_devPub!);
  Future<String?> get mnemonic => _ss.read(key: _kMnemonic);

  // ── BIP-39 wordlist ─────────────────────────────────────────────
  Future<List<String>> _words() async {
    if (_wl != null) return _wl!;
    final raw = await rootBundle.loadString('assets/bip39_en.txt');
    _wl = raw
        .split('\n')
        .map((w) => w.trim())
        .where((w) => w.isNotEmpty)
        .toList();
    if (_wl!.length != 2048) {
      throw StateError('BIP-39 wordlist: 2048 ожидалось, ${_wl!.length}');
    }
    return _wl!;
  }

  Future<String> generateMnemonic() async {
    final words = await _words();
    final entropy = _randomBytes(16);
    final hash = (await Sha256().hash(entropy)).bytes;
    final checksum = hash[0] >> 4;
    final bits =
        _bitsFromBytes(entropy) + checksum.toRadixString(2).padLeft(4, '0');
    final out = <String>[];
    for (var i = 0; i < 12; i++) {
      final idx = int.parse(bits.substring(i * 11, (i + 1) * 11), radix: 2);
      out.add(words[idx]);
    }
    return out.join(' ');
  }

  Future<bool> validateMnemonic(String mnemonic) async {
    final words = await _words();
    final parts = mnemonic.trim().toLowerCase().split(RegExp(r'\s+'));
    if (parts.length != 12) return false;
    var bits = '';
    for (final w in parts) {
      final idx = words.indexOf(w);
      if (idx < 0) return false;
      bits += idx.toRadixString(2).padLeft(11, '0');
    }
    final entropy = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      entropy[i] = int.parse(bits.substring(i * 8, (i + 1) * 8), radix: 2);
    }
    final cs = int.parse(bits.substring(128, 132), radix: 2);
    final hash = (await Sha256().hash(entropy)).bytes;
    return (hash[0] >> 4) == cs;
  }

  // ── Identity / device derivation ────────────────────────────────
  Future<Uint8List> _mnemonicToSeed(String mnemonic) async {
    final p = Pbkdf2(
      macAlgorithm: Hmac.sha512(),
      iterations: 2048,
      bits: 512,
    );
    final k = await p.deriveKey(
      secretKey: SecretKey(utf8.encode(mnemonic.trim().toLowerCase())),
      nonce: utf8.encode('mnemonicghostchat-v2'),
    );
    return Uint8List.fromList(await k.extractBytes());
  }

  Future<Uint8List> _hkdf(List<int> ikm, String info) async {
    final h = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final k = await h.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: Uint8List(32),
      info: utf8.encode(info),
    );
    return Uint8List.fromList(await k.extractBytes());
  }

  Future<Uint8List> signWithIdentity(List<int> msg) async {
    final kp = await _ed.newKeyPairFromSeed(_seed32!);
    final sig = await _ed.sign(msg, keyPair: kp);
    return Uint8List.fromList(sig.bytes);
  }

  // ── Сообщения ───────────────────────────────────────────────────
  Future<String> encryptV2(Uint8List recipientDevicePub, List<int> pt) async {
    final eph = await _x.newKeyPair();
    final ephPub = await eph.extractPublicKey();
    final sh = await _x.sharedSecretKey(
      keyPair: eph,
      remotePublicKey: SimplePublicKey(
        recipientDevicePub,
        type: KeyPairType.x25519,
      ),
    );
    final aes = SecretKey(await _hkdf(await sh.extractBytes(), 'ghostchat-v2-msg'));
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

  Future<Uint8List?> decryptForMe(String envelopeB64) async {
    if (_devPriv == null) return null;
    final raw = base64.decode(envelopeB64);
    if (raw.length < 32 + 12 + 16) return null;
    final ephPub = raw.sublist(0, 32);
    final iv = raw.sublist(32, 44);
    final ctTag = raw.sublist(44);
    final ct = ctTag.sublist(0, ctTag.length - 16);
    final tag = ctTag.sublist(ctTag.length - 16);
    try {
      final kp = await _x.newKeyPairFromSeed(_devPriv!);
      final sh = await _x.sharedSecretKey(
        keyPair: kp,
        remotePublicKey: SimplePublicKey(
          Uint8List.fromList(ephPub),
          type: KeyPairType.x25519,
        ),
      );
      final aes = SecretKey(
        await _hkdf(await sh.extractBytes(), 'ghostchat-v2-msg'),
      );
      final gcm = AesGcm.with256bits();
      final clear = await gcm.decrypt(
        SecretBox(ct, nonce: iv, mac: Mac(tag)),
        secretKey: aes,
      );
      return Uint8List.fromList(clear);
    } catch (e) {
      if (kDebugMode) print('[cryptoV2 decrypt] $e');
      return null;
    }
  }

  Future<Uint8List> proofSignature() =>
      signWithIdentity(utf8.encode('ghostchat-v2-identity-claim'));
  Future<Uint8List> signedPrekeySig() => signWithIdentity(_devPub!);

  // ── Жизненный цикл ключей ───────────────────────────────────────
  /// Загрузить v2-ключи; при первом запуске — сгенерировать (mnemonic +
  /// identity + device) и сохранить. Публикация на сервер — отдельно (в репо).
  Future<void> ensureKeys() async {
    final seedB64 = await _ss.read(key: _kSeed);
    if (seedB64 != null) {
      _seed32 = base64.decode(seedB64);
      _idPub = base64.decode((await _ss.read(key: _kIdPub))!);
      _devPriv = base64.decode((await _ss.read(key: _kDevPriv))!);
      _devPub = base64.decode((await _ss.read(key: _kDevPub))!);
      return;
    }
    final mnemonic = await generateMnemonic();
    final seed64 = await _mnemonicToSeed(mnemonic);
    final seed32 = await _hkdf(seed64, 'ghostchat-v2-identity');
    final idKp = await _ed.newKeyPairFromSeed(seed32);
    final idPub = await idKp.extractPublicKey();
    final devKp = await _x.newKeyPair();
    final devPub = await devKp.extractPublicKey();
    final devPriv = await devKp.extractPrivateKeyBytes();
    _seed32 = seed32;
    _idPub = Uint8List.fromList(idPub.bytes);
    _devPriv = Uint8List.fromList(devPriv);
    _devPub = Uint8List.fromList(devPub.bytes);
    await _ss.write(key: _kSeed, value: base64.encode(_seed32!));
    await _ss.write(key: _kIdPub, value: base64.encode(_idPub!));
    await _ss.write(key: _kDevPriv, value: base64.encode(_devPriv!));
    await _ss.write(key: _kDevPub, value: base64.encode(_devPub!));
    await _ss.write(key: _kMnemonic, value: mnemonic);
  }

  // ── utils ──
  Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  String _bitsFromBytes(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(2).padLeft(8, '0'));
    }
    return sb.toString();
  }
}
