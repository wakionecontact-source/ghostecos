// One-shot GhostChat protocol probe.
//
// This exercises legacy P-256 and signed sealed-message wire formats while
// keeping probe keys in memory, separate from the installed app and user keys.
//
// Run from the Flutter project:
//   dart run tool/ghostchat_probe.dart

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart';
import 'package:ghost/services/chat_message_auth.dart';

const _defaultBase = 'https://ghostecos.duckdns.org';
final _curve = ECDomainParameters('secp256r1');

class _KeyPair {
  final BigInt privateD;
  final Uint8List publicRaw;

  const _KeyPair(this.privateD, this.publicRaw);
}

class _Account {
  final String username;
  final String password;
  final String deviceId;
  final String token;
  final _KeyPair keys;

  const _Account({
    required this.username,
    required this.password,
    required this.deviceId,
    required this.token,
    required this.keys,
  });
}

class _SigningIdentity {
  final SimpleKeyPair keyPair;
  final String publicKeyB64;

  const _SigningIdentity(this.keyPair, this.publicKeyB64);
}

class _Api {
  final Dio _dio;

  _Api(String base)
    : _dio = Dio(
        BaseOptions(
          baseUrl: base.replaceFirst(RegExp(r'/*$'), ''),
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 30),
        ),
      );

  Options _options(_Account? account) => Options(
    headers: {
      'Content-Type': 'application/json',
      if (account != null) 'Authorization': 'Bearer ${account.token}',
      if (account != null) 'X-Device-Id': account.deviceId,
    },
  );

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body, {
    _Account? account,
  }) async {
    try {
      final r = await _dio.post(path, data: body, options: _options(account));
      return _map(r.data);
    } on DioException catch (e) {
      throw StateError(
        'POST $path → ${e.response?.statusCode}: ${e.response?.data ?? e.message}',
      );
    }
  }

  Future<Map<String, dynamic>> get(String path, {_Account? account}) async {
    try {
      final r = await _dio.get(path, options: _options(account));
      return _map(r.data);
    } on DioException catch (e) {
      throw StateError(
        'GET $path → ${e.response?.statusCode}: ${e.response?.data ?? e.message}',
      );
    }
  }

  static Map<String, dynamic> _map(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    throw StateError('Ожидался JSON-объект, получено ${value.runtimeType}');
  }
}

_KeyPair _newKeyPair() {
  final gen = ECKeyGenerator();
  final rnd = FortunaRandom();
  rnd.seed(
    KeyParameter(
      Uint8List.fromList(
        List<int>.generate(32, (_) => Random.secure().nextInt(256)),
      ),
    ),
  );
  gen.init(ParametersWithRandom(ECKeyGeneratorParameters(_curve), rnd));
  final pair = gen.generateKeyPair();
  final priv = pair.privateKey as ECPrivateKey;
  final pub = pair.publicKey as ECPublicKey;
  return _KeyPair(priv.d!, _pubToRaw(pub));
}

Uint8List _pubToRaw(ECPublicKey pub) {
  final q = pub.Q!;
  final x = _encodeBigInt(q.x!.toBigInteger()!, 32);
  final y = _encodeBigInt(q.y!.toBigInteger()!, 32);
  final out = Uint8List(65)..[0] = 0x04;
  out.setRange(1, 33, x);
  out.setRange(33, 65, y);
  return out;
}

ECPublicKey _rawToPub(Uint8List raw) {
  final body = raw.length == 65 && raw[0] == 0x04 ? raw.sublist(1) : raw;
  if (body.length != 64)
    throw StateError('P-256 public key has ${body.length} bytes');
  final x = _decodeBigInt(body.sublist(0, 32));
  final y = _decodeBigInt(body.sublist(32, 64));
  return ECPublicKey(_curve.curve.createPoint(x, y), _curve);
}

Uint8List _encodeBigInt(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0 && v > BigInt.zero; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return out;
}

BigInt _decodeBigInt(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte & 0xff);
  }
  return value;
}

Uint8List _shared(BigInt privateD, Uint8List peerPub) {
  final agreement = ECDHBasicAgreement()..init(ECPrivateKey(privateD, _curve));
  return _encodeBigInt(agreement.calculateAgreement(_rawToPub(peerPub)), 32);
}

Uint8List _v1AesKey(BigInt privateD, Uint8List peerPub) {
  final hkdf = HKDFKeyDerivator(SHA256Digest())
    ..init(
      HkdfParameters(
        _shared(privateD, peerPub),
        32,
        Uint8List(32),
        utf8.encode('ghostchat-msg-v1'),
      ),
    );
  final out = Uint8List(32);
  hkdf.deriveKey(null, 0, out, 0);
  return out;
}

String _encryptV1(BigInt privateD, Uint8List receiverPub, String plaintext) {
  final iv = Uint8List.fromList(
    List<int>.generate(12, (_) => Random.secure().nextInt(256)),
  );
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(
        KeyParameter(_v1AesKey(privateD, receiverPub)),
        128,
        iv,
        Uint8List(0),
      ),
    );
  final ct = cipher.process(Uint8List.fromList(utf8.encode(plaintext)));
  return base64Encode(Uint8List.fromList([...iv, ...ct]));
}

String _decryptV1(BigInt privateD, Uint8List senderPub, String envelope) {
  final bytes = base64Decode(envelope);
  final iv = Uint8List.fromList(bytes.sublist(0, 12));
  final ct = Uint8List.fromList(bytes.sublist(12));
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      false,
      AEADParameters(
        KeyParameter(_v1AesKey(privateD, senderPub)),
        128,
        iv,
        Uint8List(0),
      ),
    );
  return utf8.decode(cipher.process(ct));
}

String _encryptSealed({
  required Uint8List receiverPub,
  required Map<String, dynamic> payload,
  required String fromUsername,
}) {
  final eph = _newKeyPair();
  final full = {
    ...payload,
    'from_username': fromUsername,
    'ts': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
  };
  final iv = Uint8List.fromList(
    List<int>.generate(12, (_) => Random.secure().nextInt(256)),
  );
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(
        KeyParameter(_shared(eph.privateD, receiverPub)),
        128,
        iv,
        Uint8List(0),
      ),
    );
  final ct = cipher.process(Uint8List.fromList(utf8.encode(jsonEncode(full))));
  return base64Encode(Uint8List.fromList([...eph.publicRaw, ...iv, ...ct]));
}

Map<String, dynamic> _decryptSealed(BigInt privateD, String envelope) {
  final bytes = base64Decode(envelope);
  final ephPub = Uint8List.fromList(bytes.sublist(0, 65));
  final iv = Uint8List.fromList(bytes.sublist(65, 77));
  final ct = Uint8List.fromList(bytes.sublist(77));
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      false,
      AEADParameters(
        KeyParameter(_shared(privateD, ephPub)),
        128,
        iv,
        Uint8List(0),
      ),
    );
  return Map<String, dynamic>.from(
    jsonDecode(utf8.decode(cipher.process(ct))) as Map,
  );
}

Future<_Account> _register(_Api api, int slot) async {
  final suffix = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final username = 'codexprobe${suffix.substring(suffix.length - 7)}$slot';
  final password = 'Probe_${suffix}_$slot!';
  final deviceId = 'codex-probe-$suffix-$slot';
  final keys = _newKeyPair();
  final data = await api.post('/api/soc/register', {
    'username': username,
    'display_name': 'Codex Probe $slot',
    'password': password,
    'age_18_confirm': true,
    'device_id': deviceId,
    'device_name': 'Codex GhostChat probe #$slot',
    'platform': 'windows',
  });
  final token = data['token'] as String?;
  if (token == null || token.isEmpty)
    throw StateError('Регистрация $username не вернула token');
  final account = _Account(
    username: username,
    password: password,
    deviceId: deviceId,
    token: token,
    keys: keys,
  );
  await api.post('/api/chat/keys/upload', {
    'x25519_pub': base64Encode(keys.publicRaw),
    'storage_mode': 'local',
  }, account: account);
  return account;
}

Future<_SigningIdentity> _publishProbeIdentity(
  _Api api,
  _Account account,
) async {
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final proof = await algorithm.sign(
    utf8.encode('ghostchat-v2-identity-claim'),
    keyPair: keyPair,
  );
  final publicKeyB64 = base64Encode(publicKey.bytes);
  await api.post('/api/chat/v2/identity/publish', {
    'identity_pub': publicKeyB64,
    'proof_signature': base64Encode(proof.bytes),
  }, account: account);
  return _SigningIdentity(keyPair, publicKeyB64);
}

Future<void> _writeAccounts(String base, List<_Account> accounts) async {
  final outDir = Directory('work/ghostchat_probe')..createSync(recursive: true);
  final out = File('${outDir.path}/accounts.json');
  await out.writeAsString(
    const JsonEncoder.withIndent('  ')
        .convert({
          'base': base,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'accounts': [],
        })
        .replaceFirst(
          '"accounts": []',
          '"accounts": ${jsonEncode(accounts.map((a) => {
            'username': a.username,
            'password': a.password,
            'token': a.token,
            'device_id': a.deviceId,
            // This file is local-only and belongs to disposable probe accounts.
            // Never use this format for a real GhostChat account backup.
            'private_d_b64': base64Encode(_encodeBigInt(a.keys.privateD, 32)),
            'public_raw_b64': base64Encode(a.keys.publicRaw),
          }).toList())}',
        ),
  );
  stdout.writeln('Реквизиты и probe-ключ сохранены локально: ${out.path}');
}

Future<_Account> _readSavedSender(String base) async {
  final file = File('work/ghostchat_probe/accounts.json');
  if (!file.existsSync()) {
    throw StateError(
      'Нет work/ghostchat_probe/accounts.json — сначала отправь probe',
    );
  }
  final root = jsonDecode(await file.readAsString()) as Map;
  final rows = (root['accounts'] as List?) ?? const [];
  if (rows.isEmpty) throw StateError('В accounts.json нет тестового аккаунта');
  final row = Map<String, dynamic>.from(rows.first as Map);
  final privateB64 = row['private_d_b64'] as String?;
  final publicB64 = row['public_raw_b64'] as String?;
  if (privateB64 == null || publicB64 == null) {
    throw StateError(
      'В accounts.json нет приватного probe-ключа; создай новый target-only probe',
    );
  }
  return _Account(
    username: row['username'] as String,
    password: row['password'] as String,
    token: row['token'] as String,
    deviceId: row['device_id'] as String,
    keys: _KeyPair(
      _decodeBigInt(base64Decode(privateB64)),
      Uint8List.fromList(base64Decode(publicB64)),
    ),
  );
}

String _normalizeTarget(String raw) =>
    raw.trim().toLowerCase().replaceFirst('@', '');

Future<int> _sendToTarget(
  _Api api,
  _Account sender,
  String rawTarget, {
  String? text,
}) async {
  final target = _normalizeTarget(rawTarget);
  if (target.isEmpty) throw StateError('Не указан получатель');
  final targetDirectory = await api.get(
    '/api/chat/keys/$target',
    account: sender,
  );
  final targetPubB64 = targetDirectory['x25519_pub'] as String?;
  if (targetPubB64 == null || targetPubB64.isEmpty) {
    throw StateError('@$target не опубликовал E2E-ключ — отправка невозможна');
  }
  final message =
      text ??
      'Повторный тест от Codex через код GhostChat. Ответь на это сообщение, пожалуйста.';
  final cipher = _encryptV1(
    sender.keys.privateD,
    base64Decode(targetPubB64),
    jsonEncode({'type': 'msg', 'text': message}),
  );
  final sent = await api.post('/api/chat/send', {
    'to_username': target,
    'ciphertext': cipher,
  }, account: sender);
  final id = sent['id'] as int;
  stdout.writeln('SENT @$target: $id (от @${sender.username})');
  return id;
}

Future<void> _receiveSaved(_Api api, _Account account) async {
  final pending = await api.get('/api/chat/pending', account: account);
  final rows = (pending['messages'] as List? ?? const [])
      .whereType<Map>()
      .map(Map<String, dynamic>.from)
      .toList();
  if (rows.isEmpty) {
    stdout.writeln('Ответов пока нет: pending пуст.');
    return;
  }
  final ackIds = <dynamic>[];
  for (final row in rows) {
    final from = row['from_username'] as String? ?? '?';
    try {
      final directory = await api.get(
        '/api/chat/keys/${_normalizeTarget(from)}',
        account: account,
      );
      final senderPub = base64Decode(directory['x25519_pub'] as String);
      final plaintext = _decryptV1(
        account.keys.privateD,
        senderPub,
        row['ciphertext'] as String,
      );
      final payload = Map<String, dynamic>.from(jsonDecode(plaintext) as Map);
      stdout.writeln(
        'RECEIVED id=${row['id']} from @$from: ${payload['text'] ?? plaintext}',
      );
      ackIds.add(row['id']);
    } catch (e) {
      stdout.writeln('DECRYPT FAILED id=${row['id']} from @$from: $e');
    }
  }
  if (ackIds.isNotEmpty) {
    await api.post('/api/chat/ack', {'ids': ackIds}, account: account);
    stdout.writeln('ACK: ${ackIds.length}');
  }
}

Future<void> main() async {
  final base = Platform.environment['GHOSTCHAT_PROBE_BASE'] ?? _defaultBase;
  final api = _Api(base);

  if (Platform.environment['GHOSTCHAT_PROBE_RECEIVE'] == '1') {
    final account = await _readSavedSender(base);
    await _receiveSaved(api, account);
    return;
  }

  if (Platform.environment['GHOSTCHAT_PROBE_SEND_MANY'] == '1') {
    final account = await _readSavedSender(base);
    final target = _normalizeTarget(
      Platform.environment['GHOSTCHAT_PROBE_TARGET'] ?? 'waki',
    );
    for (var i = 1; i <= 5; i++) {
      await _sendToTarget(
        api,
        account,
        target,
        text: 'Сообщение подряд $i/5 — тест GhostChat.',
      );
    }
    return;
  }

  final target = _normalizeTarget(
    Platform.environment['GHOSTCHAT_PROBE_TARGET'] ?? '',
  );
  if (Platform.environment['GHOSTCHAT_PROBE_ONLY_TARGET'] == '1') {
    stdout.writeln('GhostChat target probe: $base');
    final sender = await _register(api, 1);
    await _sendToTarget(api, sender, target);
    await _writeAccounts(base, [sender]);
    return;
  }

  stdout.writeln('GhostChat probe: $base');
  stdout.writeln('Регистрирую две изолированные тестовые учётки…');
  final sender = await _register(api, 1);
  final receiver = await _register(api, 2);
  final senderIdentity = await _publishProbeIdentity(api, sender);

  final senderKeys = base64Encode(sender.keys.publicRaw);
  final receiverKeys = base64Encode(receiver.keys.publicRaw);
  stdout.writeln('U1: @${sender.username}');
  stdout.writeln('U2: @${receiver.username}');

  final receiverDirectory = await api.get(
    '/api/chat/keys/${receiver.username}',
    account: sender,
  );
  final receiverPub = base64Decode(receiverDirectory['x25519_pub'] as String);
  if (base64Encode(receiverPub) != receiverKeys) {
    throw StateError('Сервер вернул другой ключ получателя');
  }
  final senderDirectory = await api.get(
    '/api/chat/keys/${sender.username}',
    account: receiver,
  );
  final senderPub = base64Decode(senderDirectory['x25519_pub'] as String);
  if (base64Encode(senderPub) != senderKeys) {
    throw StateError('Сервер вернул другой ключ отправителя');
  }

  final v1Text = 'codex probe legacy ${DateTime.now().toIso8601String()}';
  final v1Cipher = _encryptV1(
    sender.keys.privateD,
    receiverPub,
    jsonEncode({'type': 'msg', 'text': v1Text}),
  );
  final v1Sent = await api.post('/api/chat/send', {
    'to_username': receiver.username,
    'ciphertext': v1Cipher,
  }, account: sender);
  final pendingV1 = await api.get('/api/chat/pending', account: receiver);
  final v1Rows = (pendingV1['messages'] as List? ?? const [])
      .whereType<Map>()
      .map(Map<String, dynamic>.from)
      .where((m) => m['id'] == v1Sent['id'])
      .toList();
  if (v1Rows.length != 1)
    throw StateError('Обычное сообщение не попало в pending');
  final v1Plain = _decryptV1(
    receiver.keys.privateD,
    senderPub,
    v1Rows.single['ciphertext'] as String,
  );
  final v1Payload = Map<String, dynamic>.from(jsonDecode(v1Plain) as Map);
  if (v1Payload['text'] != v1Text)
    throw StateError('Обычное сообщение расшифровалось неверно');
  await api.post('/api/chat/ack', {
    'ids': [v1Sent['id']],
  }, account: receiver);
  stdout.writeln('OK legacy send → pending → decrypt → ack');

  final sealedText = 'codex probe sealed ${DateTime.now().toIso8601String()}';
  final sealedCipher = _encryptSealed(
    receiverPub: receiverPub,
    fromUsername: sender.username,
    payload: {'type': 'msg', 'text': sealedText},
  );
  final sealedSignature = await Ed25519().sign(
    ChatMessageAuth.sealedEnvelopeBytes(
      senderIdentityPub: senderIdentity.publicKeyB64,
      toUsername: receiver.username,
      ciphertext: sealedCipher,
    ),
    keyPair: senderIdentity.keyPair,
  );
  final sealedSent = await api.post('/api/chat/send_sealed', {
    'to_username': receiver.username,
    'ciphertext': sealedCipher,
    'sender_identity_pub': senderIdentity.publicKeyB64,
    'signature': base64Encode(sealedSignature.bytes),
  }, account: sender);
  final pendingSealed = await api.get(
    '/api/chat/pending_sealed',
    account: receiver,
  );
  final sealedRows = (pendingSealed['messages'] as List? ?? const [])
      .whereType<Map>()
      .map(Map<String, dynamic>.from)
      .where((m) => m['id'] == sealedSent['id'])
      .toList();
  if (sealedRows.length != 1)
    throw StateError('Sealed-сообщение не попало в pending');
  if (sealedRows.single['sender_identity_pub'] != senderIdentity.publicKeyB64 ||
      sealedRows.single['signature'] != base64Encode(sealedSignature.bytes)) {
    throw StateError('Server omitted authenticated sealed-sender metadata');
  }
  final sealedPayload = _decryptSealed(
    receiver.keys.privateD,
    sealedRows.single['ciphertext'] as String,
  );
  if (sealedPayload['text'] != sealedText ||
      sealedPayload['from_username'] != sender.username) {
    throw StateError('Sealed-сообщение расшифровалось неверно');
  }
  await api.post('/api/chat/ack_sealed', {
    'ids': [sealedSent['id']],
  }, account: receiver);
  stdout.writeln('OK sealed send → pending_sealed → decrypt → ack_sealed');

  if (target.isNotEmpty) {
    final targetDirectory = await api.get(
      '/api/chat/keys/$target',
      account: sender,
    );
    final targetPubB64 = targetDirectory['x25519_pub'] as String?;
    if (targetPubB64 == null || targetPubB64.isEmpty) {
      throw StateError(
        '@$target не опубликовал E2E-ключ — отправка невозможна',
      );
    }
    final targetText =
        'Тестовое сообщение от Codex через код GhostChat. Ответь на него, пожалуйста.';
    final targetCipher = _encryptV1(
      sender.keys.privateD,
      base64Decode(targetPubB64),
      jsonEncode({'type': 'msg', 'text': targetText}),
    );
    final targetSent = await api.post('/api/chat/send', {
      'to_username': target,
      'ciphertext': targetCipher,
    }, account: sender);
    stdout.writeln(
      'SENT @$target: ${targetSent['id']} (от @${sender.username})',
    );
  }

  final outDir = Directory('work/ghostchat_probe')..createSync(recursive: true);
  final out = File('${outDir.path}/accounts.json');
  await out.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'base': base,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'accounts': [
        {
          'username': sender.username,
          'password': sender.password,
          'token': sender.token,
          'device_id': sender.deviceId,
        },
        {
          'username': receiver.username,
          'password': receiver.password,
          'token': receiver.token,
          'device_id': receiver.deviceId,
        },
      ],
    }),
  );
  stdout.writeln(
    'PASS: оба протокола прошли. Реквизиты сохранены локально: ${out.path}',
  );
}
