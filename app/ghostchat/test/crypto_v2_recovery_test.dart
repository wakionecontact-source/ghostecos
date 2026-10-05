import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/crypto_v2.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v2 identity recovery keeps the new device key', () async {
    const account = 'crypto-v2-recovery-test';
    const password = 'correct horse battery staple';
    FlutterSecureStorage.setMockInitialValues(<String, String>{});

    final crypto = CryptoV2.instance;
    await crypto.regenerateKeys(account: account);
    await crypto.ensureKeys(account: account);
    final originalIdentity = List<int>.from(crypto.identityPub);
    final encrypted = await crypto.exportEncryptedIdentityForServer(password);

    await crypto.regenerateKeys(account: account);
    await crypto.ensureKeys(account: account);
    final newDevice = List<int>.from(crypto.devicePub);

    await crypto.importEncryptedIdentityFromServer(
      encryptedB64: encrypted['identity_priv_encrypted']!,
      saltB64: encrypted['identity_salt']!,
      password: password,
      account: account,
    );

    expect(crypto.identityPub, orderedEquals(originalIdentity));
    expect(crypto.devicePub, orderedEquals(newDevice));
  });
}
