import 'package:package_info_plus/package_info_plus.dart';

import 'constants.dart';

/// Cached installed app version shared by every GhostChat API transport.
class GhostChatAppVersion {
  GhostChatAppVersion._();

  static const headerName = 'X-GhostChat-Version';
  static Future<String>? _cached;

  static Future<String> current() => _cached ??= _load();

  static Future<String> _load() async {
    try {
      final version = (await PackageInfo.fromPlatform().timeout(
        const Duration(seconds: 3),
      )).version.trim();
      if (version.isNotEmpty) return version;
    } catch (_) {
      // Keep API calls available if platform package metadata is unavailable.
    }
    return K.appVersion;
  }
}
