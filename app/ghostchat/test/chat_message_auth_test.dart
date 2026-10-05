import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/chat_message_auth.dart';
import 'package:ghost/services/crypto_v2.dart';

void main() {
  test(
    'v2 envelope signature bytes bind identity, recipient, device and data',
    () {
      final bytes = ChatMessageAuth.v2EnvelopeBytes(
        senderIdentityPub: 'identity-b64',
        toUsername: ' Alice ',
        targetDeviceId: 42,
        envelope: 'cipher-b64',
      );
      expect(
        utf8.decode(bytes),
        'ghostchat-v2-envelope-v1\u0000identity-b64\u0000alice\u000042\u0000cipher-b64',
      );
    },
  );

  test('sealed envelope signature bytes are domain separated', () {
    final bytes = ChatMessageAuth.sealedEnvelopeBytes(
      senderIdentityPub: 'identity-b64',
      toUsername: 'Alice',
      ciphertext: 'cipher-b64',
    );
    expect(
      utf8.decode(bytes),
      'ghostchat-sealed-envelope-v1\u0000identity-b64\u0000alice\u0000cipher-b64',
    );
  });

  test('P2P signature JSON is stable across map insertion order', () {
    final first = ChatMessageAuth.p2pPayloadBytes({
      'z': 2,
      'nested': {'b': true, 'a': 1},
    });
    final second = ChatMessageAuth.p2pPayloadBytes({
      'nested': {'a': 1, 'b': true},
      'z': 2,
    });
    expect(first, orderedEquals(second));
    expect(utf8.decode(first), '{"nested":{"a":1,"b":true},"z":2}');
  });

  test(
    'CryptoV2 verifies a message identity signature and rejects tampering',
    () async {
      final algorithm = Ed25519();
      final pair = await algorithm.newKeyPair();
      final publicKey = await pair.extractPublicKey();
      final bytes = Uint8List.fromList(utf8.encode('authenticated envelope'));
      final signature = await algorithm.sign(bytes, keyPair: pair);

      expect(
        await CryptoV2.instance.verifyIdentitySignature(
          identityPub: Uint8List.fromList(publicKey.bytes),
          signature: Uint8List.fromList(signature.bytes),
          message: bytes,
        ),
        isTrue,
      );
      expect(
        await CryptoV2.instance.verifyIdentitySignature(
          identityPub: Uint8List.fromList(publicKey.bytes),
          signature: Uint8List.fromList(signature.bytes),
          message: utf8.encode('tampered envelope'),
        ),
        isFalse,
      );
    },
  );
}
