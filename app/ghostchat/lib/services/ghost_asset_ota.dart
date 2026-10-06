import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asn1lib/asn1lib.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/signers/rsa_signer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../core/api/http_client.dart';
import '../core/local/app_logger.dart';

/// Signed, data-only asset overlay. It never evaluates downloaded code.
///
/// The overlay currently applies to assets requested through Flutter's
/// DefaultAssetBundle (for example Image.asset and SvgPicture.asset).
class GhostAssetOta {
  GhostAssetOta._();

  static final GhostAssetOta instance = GhostAssetOta._();

  static const _appId = 'ghostchat-android';
  static const _stateKey = 'gc_asset_ota_state_v1';
  static const _maxFiles = 5000;
  static const _maxFileBytes = 256 * 1024 * 1024;
  static const _maxUpdateBytes = 512 * 1024 * 1024;

  final ValueNotifier<int> revisionNotifier = ValueNotifier(0);
  Map<String, String> _assetHashes = <String, String>{};
  int? _releaseId;
  Directory? _blobDirectory;
  Future<void>? _refreshInFlight;
  bool _loaded = false;

  int? get installedReleaseId => _releaseId;

  Future<void> loadLocal() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final support = await getApplicationSupportDirectory();
      _blobDirectory = Directory(
        p.join(support.path, 'ghostchat', 'ota-assets'),
      );
      await _blobDirectory!.create(recursive: true);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_stateKey);
      if (raw != null) {
        final state = jsonDecode(raw);
        if (state is Map && state['protocol'] == 1) {
          final id = state['release_id'];
          _releaseId = id is int && id > 0 ? id : null;
          final assets = state['assets'];
          if (assets is Map) {
            for (final entry in assets.entries) {
              final path = entry.key;
              final hash = entry.value;
              if (path is String &&
                  hash is String &&
                  isValidAssetPath(path) &&
                  _isHash(hash) &&
                  await _blobFile(hash).exists()) {
                _assetHashes[path] = hash;
              }
            }
          }
          if (_assetHashes.length != (assets is Map ? assets.length : 0)) {
            // Missing local blobs invalidate the release marker so the server
            // will compare and send the files again instead of trusting stale
            // preferences.
            _releaseId = null;
          }
        }
      }
      revisionNotifier.value++;
    } catch (error, stack) {
      appLog.warn(
        'asset-ota',
        'local overlay could not be loaded: $error\n$stack',
      );
    }
  }

  Future<void> refresh() async {
    await loadLocal();
    final running = _refreshInFlight;
    if (running != null) return running;
    final operation = _refreshFromServer();
    _refreshInFlight = operation;
    try {
      await operation;
    } finally {
      if (identical(_refreshInFlight, operation)) _refreshInFlight = null;
    }
  }

  Future<ByteData?> loadOverride(String key) async {
    final hash = _assetHashes[key];
    if (hash == null) return null;
    try {
      final bytes = await _blobFile(hash).readAsBytes();
      return ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    } on FileSystemException catch (error) {
      appLog.warn('asset-ota', 'cached asset $key could not be read: $error');
      return null;
    }
  }

  Future<ByteData> loadAssetData(String key) async {
    await loadLocal();
    final override = await loadOverride(key);
    if (override != null) return override;
    return rootBundle.load(key);
  }

  static bool isValidAssetPath(String value) {
    if (!RegExp(
          r'^assets/[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$',
        ).hasMatch(value) ||
        value.contains('\\') ||
        value.contains('//')) {
      return false;
    }
    return value
        .split('/')
        .skip(1)
        .every((part) => part.isNotEmpty && part != '.' && part != '..');
  }

  static bool verifyManifestSignature({
    required String manifestJson,
    required String signatureBase64,
    required String publicKeyBase64,
  }) {
    try {
      final publicKeyDer = base64Decode(publicKeyBase64);
      final outer = ASN1Parser(Uint8List.fromList(publicKeyDer)).nextObject();
      if (outer is! ASN1Sequence || outer.elements.length != 2) return false;
      final rsaObject = switch ((outer.elements[0], outer.elements[1])) {
        (ASN1Integer _, ASN1Integer _) => outer,
        (_, ASN1BitString subjectPublicKey) => ASN1Parser(
          Uint8List.fromList(subjectPublicKey.stringValue),
        ).nextObject(),
        _ => null,
      };
      if (rsaObject is! ASN1Sequence || rsaObject.elements.length != 2) {
        return false;
      }
      final modulus = rsaObject.elements[0];
      final exponent = rsaObject.elements[1];
      if (modulus is! ASN1Integer || exponent is! ASN1Integer) return false;

      final verifier = RSASigner(SHA256Digest(), '0609608648016503040201')
        ..init(
          false,
          PublicKeyParameter<RSAPublicKey>(
            RSAPublicKey(modulus.valueAsBigInteger, exponent.valueAsBigInteger),
          ),
        );
      return verifier.verifySignature(
        Uint8List.fromList(utf8.encode(manifestJson)),
        RSASignature(base64Decode(signatureBase64)),
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> _refreshFromServer() async {
    try {
      final requestHashes = _availableHashes();
      final response = await HttpClient.I.dio.post(
        '/api/v1/assets/check',
        data: {
          'app_id': _appId,
          'installed_release_id': _releaseId,
          'installed_hashes': requestHashes.toList(growable: false),
        },
        options: Options(
          extra: const {'skipAuth': true},
          responseType: ResponseType.json,
          headers: const {'Cache-Control': 'no-store'},
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      if (response.statusCode != 200 || response.data is! Map) return;
      final payload = Map<String, dynamic>.from(response.data as Map);
      if (payload['update_available'] != true) return;

      final manifestJson = payload['manifest_json'];
      final signature = payload['signature'];
      if (manifestJson is! String || signature is! String) {
        throw const FormatException('asset manifest signature is missing');
      }
      final config = await rootBundle.loadString('shorebird.yaml');
      final keyMatch = RegExp(
        r'^patch_public_key:\s*([A-Za-z0-9+/=]+)\s*$',
        multiLine: true,
      ).firstMatch(config);
      final publicKey = keyMatch?.group(1);
      if (publicKey == null ||
          !verifyManifestSignature(
            manifestJson: manifestJson,
            signatureBase64: signature,
            publicKeyBase64: publicKey,
          )) {
        throw const FormatException('asset manifest signature is invalid');
      }

      final manifest = jsonDecode(manifestJson);
      final assets = _parseManifest(manifest);
      final releaseId = manifest['release_id'] as int;
      if (payload['release_id'] != releaseId) {
        throw const FormatException(
          'asset release id does not match its manifest',
        );
      }

      final fileList = payload['files'];
      if (fileList is! List || fileList.length > _maxFiles) {
        throw const FormatException('invalid asset download list');
      }
      final supplied = <String, Map<String, dynamic>>{};
      for (final raw in fileList) {
        if (raw is! Map) {
          throw const FormatException('invalid asset download item');
        }
        final entry = Map<String, dynamic>.from(raw);
        final path = entry['path'];
        final expected = assets[path];
        if (path is! String ||
            expected == null ||
            !_sameAsset(entry, expected)) {
          throw const FormatException(
            'download item is not in the signed manifest',
          );
        }
        supplied[path] = entry;
      }

      var totalDownloadBytes = 0;
      for (final asset in assets.values) {
        final hash = asset['hash'] as String;
        if (await _blobFile(hash).exists()) continue;
        final download = supplied[asset['path'] as String];
        if (download == null) {
          throw const FormatException('server omitted a missing asset');
        }
        totalDownloadBytes += asset['size'] as int;
        if (totalDownloadBytes > _maxUpdateBytes) {
          throw const FormatException(
            'asset update exceeds the local size limit',
          );
        }
      }

      for (final entry in supplied.values) {
        final hash = entry['hash'] as String;
        final destination = _blobFile(hash);
        if (await destination.exists()) continue;
        await _downloadAsset(entry, destination);
      }

      for (final asset in assets.values) {
        if (!await _blobFile(asset['hash'] as String).exists()) {
          throw const FileSystemException('asset file missing after download');
        }
      }

      final nextAssets = <String, String>{
        for (final asset in assets.values)
          asset['path'] as String: asset['hash'] as String,
      };
      final prefs = await SharedPreferences.getInstance();
      final saved = await prefs.setString(
        _stateKey,
        jsonEncode({
          'protocol': 1,
          'release_id': releaseId,
          'assets': nextAssets,
        }),
      );
      if (!saved) {
        throw const FileSystemException('asset state could not be saved');
      }

      _assetHashes = nextAssets;
      _releaseId = releaseId;
      unawaited(
        _removeUnreferencedBlobs(nextAssets.values.toSet()).catchError((
          Object error,
          StackTrace stack,
        ) {
          appLog.warn(
            'asset-ota',
            'old asset cache cleanup failed: $error\n$stack',
          );
        }),
      );
      // Force Image.asset and other bundle consumers to resolve through a
      // fresh cache after the signed overlay is committed.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      revisionNotifier.value++;
      appLog.info(
        'asset-ota',
        'installed signed asset release $releaseId (${nextAssets.length} files)',
      );
    } on DioException catch (error) {
      appLog.warn('asset-ota', 'asset check/download failed: ${error.message}');
    } catch (error, stack) {
      appLog.warn('asset-ota', 'asset update was rejected: $error\n$stack');
    }
  }

  Map<String, Map<String, dynamic>> _parseManifest(dynamic raw) {
    if (raw is! Map ||
        raw['protocol'] != 1 ||
        raw['app_id'] != _appId ||
        raw['release_id'] is! int ||
        raw['release_id'] <= 0 ||
        raw['version'] is! String ||
        raw['assets'] is! List ||
        (raw['assets'] as List).length > _maxFiles) {
      throw const FormatException('unsupported or invalid asset manifest');
    }
    final result = <String, Map<String, dynamic>>{};
    for (final item in raw['assets'] as List) {
      if (item is! Map) {
        throw const FormatException('invalid asset manifest entry');
      }
      final asset = Map<String, dynamic>.from(item);
      final path = asset['path'];
      final hash = asset['hash'];
      final size = asset['size'];
      final url = asset['url'];
      if (path is! String ||
          !isValidAssetPath(path) ||
          result.containsKey(path)) {
        throw const FormatException('invalid or duplicate asset path');
      }
      if (hash is! String || !_isHash(hash)) {
        throw const FormatException('invalid asset hash');
      }
      if (size is! int || size < 1 || size > _maxFileBytes) {
        throw const FormatException('invalid asset size');
      }
      if (url is! String || !_isAllowedDownloadUrl(url)) {
        throw const FormatException('untrusted asset download URL');
      }
      result[path] = asset;
    }
    return result;
  }

  Future<void> _downloadAsset(
    Map<String, dynamic> asset,
    File destination,
  ) async {
    final temporary = File(
      '${destination.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      final response = await HttpClient.I.dio.download(
        asset['url'] as String,
        temporary.path,
        deleteOnError: true,
        options: Options(
          extra: const {'skipAuth': true},
          receiveTimeout: const Duration(minutes: 5),
        ),
      );
      if (response.statusCode != 200) {
        throw const FormatException('asset download failed');
      }
      if (await temporary.length() != asset['size'] ||
          await _sha256File(temporary) != asset['hash']) {
        throw const FormatException('asset size or SHA-256 mismatch');
      }
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Set<String> _availableHashes() => _assetHashes.values
      .where(_isHash)
      .where((hash) => _blobFile(hash).existsSync())
      .toSet();

  File _blobFile(String hash) =>
      File(p.join((_blobDirectory?.path ?? ''), '$hash.asset'));

  Future<void> _removeUnreferencedBlobs(Set<String> retainedHashes) async {
    final directory = _blobDirectory;
    if (directory == null || !await directory.exists()) return;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!name.endsWith('.asset')) continue;
      final hash = name.substring(0, name.length - '.asset'.length);
      if (_isHash(hash) && !retainedHashes.contains(hash)) {
        await entry.delete();
      }
    }
  }
}

class GhostOtaAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) =>
      GhostAssetOta.instance.loadAssetData(key);
}

bool _isAllowedDownloadUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host == K.host &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      uri.query.isEmpty &&
      uri.fragment.isEmpty &&
      RegExp(r'^/api/v1/code-ota/assets/[1-9][0-9]*$').hasMatch(uri.path);
}

bool _sameAsset(
  Map<String, dynamic> candidate,
  Map<String, dynamic> expected,
) =>
    candidate['hash'] == expected['hash'] &&
    candidate['size'] == expected['size'] &&
    candidate['url'] == expected['url'];

bool _isHash(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

Future<String> _sha256File(File file) async {
  final digest = SHA256Digest();
  await for (final chunk in file.openRead()) {
    final bytes = Uint8List.fromList(chunk);
    digest.update(bytes, 0, bytes.length);
  }
  final result = Uint8List(digest.digestSize);
  digest.doFinal(result, 0);
  return result.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
