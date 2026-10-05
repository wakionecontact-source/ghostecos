import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Receives room links from Android and keeps them pending until the app's
/// authenticated navigation shell is ready.
class RoomDeepLinkService {
  RoomDeepLinkService._();

  static final instance = RoomDeepLinkService._();

  static const _channel = MethodChannel('ghostchat/deeplink');

  final pending = ValueNotifier<String?>(null);
  bool _started = false;

  Future<void> start() async {
    if (_started || !Platform.isAndroid) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onDeepLink') {
        final raw = call.arguments?.toString();
        if (raw != null) _set(raw);
      }
      return null;
    });
    try {
      final initial = await _channel.invokeMethod<String>('getInitialLink');
      if (initial != null) _set(initial);
    } catch (_) {
      // Deep links are optional; a normal app launch must never fail because
      // the Android channel is unavailable on an older build.
    }
  }

  String? take() {
    final value = pending.value;
    pending.value = null;
    return value;
  }

  void _set(String raw) {
    final normalized = normalize(raw);
    if (normalized == null || normalized == pending.value) return;
    pending.value = normalized;
  }

  /// Converts the Android custom link into the HTTPS room link understood by
  /// RoomLinkTarget. The custom scheme may carry the original URL as `url`.
  @visibleForTesting
  static String? normalize(String raw) {
    final value = raw.trim();
    if (value.isEmpty || value.length > 8192) return null;
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    if (uri.scheme.toLowerCase() == 'https') return uri.toString();
    if (uri.scheme.toLowerCase() != 'ghostchat') return null;

    final embedded = uri.queryParameters['url'];
    if (embedded != null && embedded.isNotEmpty) {
      final embeddedUri = Uri.tryParse(embedded);
      if (embeddedUri?.scheme.toLowerCase() == 'https') {
        return embeddedUri!.toString();
      }
    }

    // Also accept direct custom links such as ghostchat://c/name and
    // ghostchat://g/123 when a browser or another app sends them directly.
    final segments = <String>[
      if (uri.host.isNotEmpty) uri.host,
      ...uri.pathSegments,
    ];
    if (segments.length == 2 &&
        (segments.first == 'c' || segments.first == 'g')) {
      return Uri.https(
        'ghostecos.duckdns.org',
        '/${segments.join('/')}',
      ).toString();
    }
    if (segments.length == 2 && segments.first == 'invite') {
      return Uri.https(
        'ghostecos.duckdns.org',
        '/${segments.join('/')}',
      ).toString();
    }
    return null;
  }
}
