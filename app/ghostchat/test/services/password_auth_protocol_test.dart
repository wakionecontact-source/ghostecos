import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/password_auth_protocol.dart';

void main() {
  test(
    'Argon2id verifier and challenge proof match the server vector',
    () async {
      final verifier = await PasswordAuthProtocol.createVerifier(
        'known-password',
        salt: List<int>.generate(16, (index) => index),
      );

      expect(verifier['salt'], 'AAECAwQFBgcICQoLDA0ODw');
      expect(
        verifier['stored_key'],
        'X60XGNHntMOK0ehFTRczX7ZJ7My_clIsQAsbx90hyCs',
      );
      expect(
        verifier['server_key'],
        'qkmyCAS2_7vZJ34Zr2WzBaJp_FP38bZ3w3Lwcr2-OgE',
      );

      final proof = await PasswordAuthProtocol.prove('known-password', {
        'purpose': 'login',
        'username': 'Example',
        'challenge_id': 'challenge-1',
        'client_nonce': 'client-nonce',
        'server_nonce': 'server-nonce',
        'context': 'context',
        ...verifier,
      });

      expect(proof.clientProof, 'FS-LqTLLSgfuSlGayJNknofeyQp-ifXvRLjXu6SoEe4');
      expect(
        proof.expectedServerProof,
        'syL8pj9OrombesFC1sdE9YDHBUZ8nfg1NSv6eDnum9A',
      );
    },
  );

  test('server proof comparison fails for changed or malformed values', () {
    const expected = 'AQID';
    expect(PasswordAuthProtocol.verifyServerProof(expected, expected), isTrue);
    expect(PasswordAuthProtocol.verifyServerProof(expected, 'AQIE'), isFalse);
    expect(
      PasswordAuthProtocol.verifyServerProof(expected, 'not base64!'),
      isFalse,
    );
  });
}
