import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Client-side half of the GhostChat password challenge protocol v1.
/// The derived Argon2/PBKDF2 output and password never enter an HTTP payload.
class PasswordAuthProtocol {
  PasswordAuthProtocol._();

  static const Map<String, dynamic> registrationKdf = {
    'name': 'argon2id',
    'version': 19,
    'iterations': 3,
    'memory_kib': 65536,
    'parallelism': 1,
    'hash_len': 32,
  };

  static final Random _random = Random.secure();

  static String newNonce() => _encode(
    List<int>.generate(32, (_) => _random.nextInt(256), growable: false),
  );

  static Future<Map<String, dynamic>> createVerifier(
    String password, {
    List<int>? salt,
  }) async {
    final verifierSalt = salt == null
        ? List<int>.generate(16, (_) => _random.nextInt(256), growable: false)
        : List<int>.from(salt, growable: false);
    final saltedPassword = await _derive(
      password,
      verifierSalt,
      registrationKdf,
    );
    final keys = await _keysFromSaltedPassword(saltedPassword);
    return {
      'salt': _encode(verifierSalt),
      'kdf': Map<String, dynamic>.from(registrationKdf),
      'stored_key': _encode(keys.storedKey),
      'server_key': _encode(keys.serverKey),
    };
  }

  static Future<String> contextForLogin({
    String? deviceId,
    String? deviceName,
    String? platform,
  }) async {
    final body = _canonicalJson({
      'device_id': deviceId ?? '',
      'device_name': deviceName ?? '',
      'platform': platform ?? '',
    });
    return _encode((await Sha256().hash(utf8.encode(body))).bytes);
  }

  static Future<String> contextForVerifier(
    Map<String, dynamic> verifier,
  ) async {
    final body = _canonicalJson(verifier);
    return _encode((await Sha256().hash(utf8.encode(body))).bytes);
  }

  static Future<PasswordProof> prove(
    String password,
    Map<String, dynamic> challenge,
  ) async {
    final purpose = challenge['purpose'];
    final username = challenge['username'];
    final challengeId = challenge['challenge_id'];
    final clientNonce = challenge['client_nonce'];
    final serverNonce = challenge['server_nonce'];
    final context = challenge['context'] ?? '';
    if (purpose is! String ||
        username is! String ||
        challengeId is! String ||
        clientNonce is! String ||
        serverNonce is! String ||
        context is! String) {
      throw const FormatException('Некорректный ответ проверки пароля');
    }

    final salt = _decode(_requiredString(challenge, 'salt'));
    final kdfRaw = challenge['kdf'];
    if (kdfRaw is! Map) {
      throw const FormatException('Некорректные параметры проверки пароля');
    }
    final kdf = Map<String, dynamic>.from(kdfRaw);
    final saltedPassword = await _derive(password, salt, kdf);
    final keys = await _keysFromSaltedPassword(saltedPassword);
    final transcript = utf8.encode(
      'ghostchat-password-v1\n'
      '$purpose\n${username.toLowerCase()}\n$challengeId\n'
      '$clientNonce\n$serverNonce\n$context',
    );
    final signature = await Hmac.sha256().calculateMac(
      transcript,
      secretKey: SecretKey(keys.storedKey),
    );
    final proof = List<int>.generate(
      keys.clientKey.length,
      (index) => keys.clientKey[index] ^ signature.bytes[index],
      growable: false,
    );
    final serverProof = await Hmac.sha256().calculateMac(<int>[
      ...utf8.encode('GhostChat Server Proof v1\n'),
      ...transcript,
    ], secretKey: SecretKey(keys.serverKey));
    return PasswordProof(
      clientProof: _encode(proof),
      expectedServerProof: _encode(serverProof.bytes),
    );
  }

  static bool verifyServerProof(String expected, dynamic received) {
    if (received is! String) return false;
    try {
      final a = _decode(expected);
      final b = _decode(received);
      if (a.length != b.length) return false;
      var difference = 0;
      for (var i = 0; i < a.length; i++) {
        difference |= a[i] ^ b[i];
      }
      return difference == 0;
    } on FormatException {
      return false;
    }
  }

  static Future<List<int>> _derive(
    String password,
    List<int> salt,
    Map<String, dynamic> kdf,
  ) async {
    final name = kdf['name'];
    final hashLength = _intParam(kdf, 'hash_len');
    if (hashLength != 32 || salt.length < 16 || salt.length > 64) {
      throw const FormatException('Некорректные параметры проверки пароля');
    }
    final secretKey = SecretKey(utf8.encode(password));
    if (name == 'argon2id') {
      final version = _intParam(kdf, 'version');
      final iterations = _intParam(kdf, 'iterations');
      final memory = _intParam(kdf, 'memory_kib');
      final parallelism = _intParam(kdf, 'parallelism');
      if (version != 19 ||
          iterations < 1 ||
          iterations > 10 ||
          memory < 8192 ||
          memory > 262144 ||
          parallelism < 1 ||
          parallelism > 8) {
        throw const FormatException('Параметры Argon2id вне допустимых границ');
      }
      final key = await Argon2id(
        parallelism: parallelism,
        memory: memory,
        iterations: iterations,
        hashLength: hashLength,
      ).deriveKey(secretKey: secretKey, nonce: salt);
      return key.extractBytes();
    }
    if (name == 'pbkdf2-sha256') {
      final iterations = _intParam(kdf, 'iterations');
      if (iterations < 100000 || iterations > 2000000) {
        throw const FormatException('Параметры PBKDF2 вне допустимых границ');
      }
      final key = await Pbkdf2.hmacSha256(
        iterations: iterations,
        bits: hashLength * 8,
      ).deriveKey(secretKey: secretKey, nonce: salt);
      return key.extractBytes();
    }
    throw const FormatException('Неизвестный алгоритм проверки пароля');
  }

  static Future<_PasswordKeys> _keysFromSaltedPassword(
    List<int> saltedPassword,
  ) async {
    final clientKey = (await Hmac.sha256().calculateMac(
      utf8.encode('GhostChat Client Key v1'),
      secretKey: SecretKey(saltedPassword),
    )).bytes;
    final storedKey = (await Sha256().hash(clientKey)).bytes;
    final serverKey = (await Hmac.sha256().calculateMac(
      utf8.encode('GhostChat Server Key v1'),
      secretKey: SecretKey(saltedPassword),
    )).bytes;
    return _PasswordKeys(clientKey, storedKey, serverKey);
  }

  static int _intParam(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is int) return value;
    if (value is num && value == value.roundToDouble()) return value.toInt();
    throw FormatException('Missing password KDF parameter: $key');
  }

  static String _requiredString(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is String && value.isNotEmpty) return value;
    throw FormatException('Missing password challenge field: $key');
  }

  static String _canonicalJson(Object? value) =>
      jsonEncode(_canonicalize(value));

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return <String, dynamic>{
        for (final key in keys) key: _canonicalize(value[key]),
      };
    }
    if (value is List) return value.map(_canonicalize).toList(growable: false);
    return value;
  }

  static String _encode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static List<int> _decode(String value) {
    if (value.isEmpty || value.length > 4096) {
      throw const FormatException('Invalid base64 value');
    }
    final padded = value.padRight(
      value.length + ((4 - value.length % 4) % 4),
      '=',
    );
    try {
      return base64Url.decode(padded);
    } on FormatException {
      throw const FormatException('Invalid base64 value');
    }
  }
}

class PasswordProof {
  const PasswordProof({
    required this.clientProof,
    required this.expectedServerProof,
  });

  final String clientProof;
  final String expectedServerProof;
}

class _PasswordKeys {
  const _PasswordKeys(this.clientKey, this.storedKey, this.serverKey);

  final List<int> clientKey;
  final List<int> storedKey;
  final List<int> serverKey;
}
