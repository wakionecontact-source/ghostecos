import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/ghost_asset_ota.dart';

void main() {
  group('Ghost asset OTA validation', () {
    test('accepts app asset bundle paths', () {
      expect(
        GhostAssetOta.isValidAssetPath('assets/app_avatars/avatar-01.png'),
        isTrue,
      );
      expect(GhostAssetOta.isValidAssetPath('assets/bip39_en.txt'), isTrue);
    });

    test('rejects traversal and non-bundle paths', () {
      for (final path in <String>[
        '../assets/secret',
        'assets/../secret',
        'assets/a//b.png',
        r'assets\secret.png',
        'packages/plugin/image.png',
        'assets/неподдерживаемое.png',
      ]) {
        expect(GhostAssetOta.isValidAssetPath(path), isFalse, reason: path);
      }
    });

    test('rejects malformed RSA keys or signatures', () {
      expect(
        GhostAssetOta.verifyManifestSignature(
          manifestJson: '{"protocol":1}',
          signatureBase64: 'not-base64',
          publicKeyBase64: 'not-base64',
        ),
        isFalse,
      );
    });

    test('verifies an RSA-SHA256 manifest and rejects tampering', () {
      const manifest = '{"protocol":1,"app_id":"ghostchat-android"}';
      const publicKey =
          'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzHTTm+NRIfP8DxZ2KQZuPobvARaCgTblFFq3c+sd0YIvq1CFX+R5WcG4+MNMJN7P1bvbvjt9z9Yn3yqXKvxz/Y6Qz6CvT0wqOAoMywyhqsjNpcI9A6/sBGlDgvGBE0CPQyc+cM+B+FrXS0Gn76PgejdRTPD1jivF78BixfiahSDhqD6G2zfwhBZzmy4kPg2as5vG7hUVwWCxrmW+g2J/BZx8kN1g4UIDnsQDtZkktgHkEZQ01qKBG62PKqNz/9XWfYBI9UOmQ2vFcFDO3kTHSVk2ohV/3auT3eyAZ1LMIbEqzXhkeL3I4vbPsijG6J8dtgPjx00XldcfxEtJ6yjPiwIDAQAB';
      const signature =
          'DGQMDUbiXwm+rNLrhxRfVMarqrkscWe8kQ38NsqUhPMKGrNjLUuGvz9uzrDtD2QLl0yBRybz508mSHchkLnyau0M+I5Bccm0cZXY8UEldF9oDgnaLstDWpc/8yGxneqTJe46FZlCaqANWn459WqSCMeEHyTwS/SBj59Wtv5PPb8RQjsvqwT6bRArKK0aDoOVngCmypbsyxYZEoY5Jqgzws09b9oBrJmI0tuKGS6OJAqjvpvTgXyoAXw/wc49WVpaXwZRHORE0QldYznGOIWZf8gHtmeaiAPp6g2JNSs7v2nv8gIyWI+vgIa6KjUzidHmBnPNgXGWyO98U3Aa9Kt7IQ==';

      expect(
        GhostAssetOta.verifyManifestSignature(
          manifestJson: manifest,
          signatureBase64: signature,
          publicKeyBase64: publicKey,
        ),
        isTrue,
      );
      expect(
        GhostAssetOta.verifyManifestSignature(
          manifestJson: '$manifest ',
          signatureBase64: signature,
          publicKeyBase64: publicKey,
        ),
        isFalse,
      );

      const pkcs1PublicKey =
          'MIIBCgKCAQEAtW8gMmSf1VLUVJpHukjVp/7XMA/V/037NkuuWQD4R42BDVwF4hTZ2kHEHsYNqnuxl28QRwdi5YT8xfSSXXMUh78FZZtxWGDjfkP504KktKWF2xkg7S9WDYOzyvnxpVYykuuBmVPpNxUYA20L5Ac3jSRcGtRKHOCoz0XlNgOWDlmIldtwhgTkLGk+u0Fy/3quB7DMtIzpJA4Wy/Z9YjXiwtPkWD5l1SVZSE9vlaG7j/EyKuZk07HK1gQMwxtDAnnVODudxleIJWqXO6Vkr+NEIlHJJJGFVEnOBId47A5rLW0m/u37gFgv+Ct9m3UV8y1HTdhsI0OkkrDkt6vV2tWc/QIDAQAB';
      const pkcs1Signature =
          'DCXyDaHJM8C0vsIVIFEFlvSrGVcSH2T+CO27WDtsHmp8VxJPGUIOJ1c2IWSaNk5wgSX++Iz2jnAMvTq3ckYFnTsH24cbrFIvg/dQkYa/fid8i8485+VEYZG7Zf68Tj3enMSRw4N4dEGNzILEMSGzPeROVjskiue/1oApierxy8sqPPjoAEHjJjhKQembQUR0S6/eZLG0tVrcyZxe133ziq/2ZCNbYlbiwMVCOga9n1zMoBedWnSazTqxc/ANtne46iYCFEwbSNQFwTCWT+V400XJGK2/jTiKigzWe1abV5cxXnmDFm71YeQOnP1vRZU/lWEGoxv5UPiWSkjMs/gesA==';
      expect(
        GhostAssetOta.verifyManifestSignature(
          manifestJson: manifest,
          signatureBase64: pkcs1Signature,
          publicKeyBase64: pkcs1PublicKey,
        ),
        isTrue,
      );
    });
  });
}
