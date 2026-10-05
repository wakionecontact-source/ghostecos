import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/call_verification_code.dart';

void main() {
  const aliceFingerprint =
      'a=fingerprint:sha-256 01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef';
  const bobFingerprint =
      'a=fingerprint:sha-256 fe:dc:ba:98:76:54:32:10:fe:dc:ba:98:76:54:32:10:fe:dc:ba:98:76:54:32:10:fe:dc:ba:98:76:54:32:10';

  test('both call endpoints derive the same five emoji check code', () async {
    final first = await CallVerificationCode.fromDescriptions(
      localSdp: '$aliceFingerprint\r\n',
      remoteSdp: '$bobFingerprint\r\n',
    );
    final second = await CallVerificationCode.fromDescriptions(
      localSdp: '$bobFingerprint\r\n',
      remoteSdp: '$aliceFingerprint\r\n',
    );

    expect(first, hasLength(5));
    expect(second, first);
  });

  test('does not show a verification code without two fingerprints', () async {
    final code = await CallVerificationCode.fromDescriptions(
      localSdp: aliceFingerprint,
      remoteSdp: '',
    );

    expect(code, isEmpty);
  });
}
