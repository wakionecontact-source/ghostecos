// Локальная проверка подписи GhostGallery: `dart run tool/gallery_verify_check.dart`.
import 'dart:convert';
import 'dart:io';

import 'package:ghost/services/gallery_signature.dart';

Future<void> main() async {
  final client = HttpClient();
  final detailResponse = await (await client.getUrl(
    Uri.parse('http://127.0.0.1:8011/api/gallery/v1/extensions/ghost_ui_v2'),
  )).close();
  final detail = Map<String, dynamic>.from(
    jsonDecode(await detailResponse.transform(utf8.decoder).join()) as Map,
  );
  final manifest = Map<String, dynamic>.from(detail['manifest'] as Map);
  final signature = detail['signature'] as String;
  final publicKey = File('assets/keys/gallery_pub.pem').readAsStringSync();

  print('canonical=${utf8.decode(GallerySignature.canonicalManifest(manifest))}');
  print(
    'signature_ok=${GallerySignature.verifyManifest(
      manifest: manifest,
      signatureBase64: signature,
      publicKeyPem: publicKey,
    )}',
  );

  final downloadRequest = await client.getUrl(
    Uri.parse(
      'http://127.0.0.1:8011/api/gallery/v1/extensions/ghost_ui_v2/download',
    ),
  );
  downloadRequest.headers.set('Authorization', 'Bearer devtoken');
  final downloadResponse = await downloadRequest.close();
  final bytes = await downloadResponse.expand((chunk) => chunk).toList();
  print('download_status=${downloadResponse.statusCode} size=${bytes.length}');
  print('sha_actual=${GallerySignature.sha256Hex(bytes)}');
  print('sha_expected=${manifest['sha256']}');
}
