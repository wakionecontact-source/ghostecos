import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'app_navigator.dart';

/// Opens only public web pages from user-visible link actions.
///
/// The backend still remains authoritative for data access. This helper is a
/// client-side safety boundary: it rejects local/special schemes, known
/// download/API/file paths and direct media URLs before handing anything to
/// the operating system browser.
class PublicPageLink {
  PublicPageLink._();

  static const _internalHosts = <String>{
    'ghostecos.duckdns.org',
    'ghostchats.duckdns.org',
    'ghostsocial.duckdns.org',
    'ghostwallet.duckdns.org',
  };

  static const _publicPrefixes = <String>[
    '/',
    '/terms',
    '/privacy',
    '/p/',
    '/c/',
    '/g/',
    '/wrapped/',
    '/invite/',
    '/bank',
    '/chat',
    '/lend/',
    '/social',
    '/sound',
  ];

  static const _blockedSegments = <String>{
    'api',
    'admin',
    'download',
    'downloads',
    'file',
    'files',
    'media',
    'stream',
    'covers',
    'assets',
    'dl',
    'upload',
    'uploads',
    '.git',
  };

  static final _filePath = RegExp(
    r'\.(?:apk|aab|ipa|exe|msi|dmg|pkg|deb|rpm|zip|rar|7z|tar|gz|bz2|pdf|docx?|xlsx?|pptx?|csv|db|sqlite3?|log|mp3|wav|ogg|oga|opus|m4a|aac|flac|webm|mp4|mov|avi)(?:$|[?#])',
    caseSensitive: false,
  );

  static bool isGhostEcosHost(String host) =>
      _internalHosts.contains(host.trim().toLowerCase());

  static Uri? parse(String raw) {
    var value = raw.trim();
    if (value.isEmpty || value.length > 4096) return null;
    if (!value.contains('://')) value = 'https://$value';

    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme.toLowerCase() != 'https') return null;
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;

    final host = uri.host.toLowerCase();
    // Never open loopback, private-network, link-local or raw-IP targets.
    if (host == 'localhost' || host.endsWith('.local')) return null;
    if (Uri.tryParse('https://$host')?.host == host &&
        RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$').hasMatch(host)) {
      return null;
    }

    final path = uri.path.toLowerCase();
    if (_filePath.hasMatch(path) ||
        path.split('/').any(_blockedSegments.contains)) {
      return null;
    }

    final internalPublicPath =
        path == '/' ||
        _publicPrefixes
            .skip(1)
            .any((prefix) => path == prefix || path.startsWith(prefix));
    if (_internalHosts.contains(host) && !internalPublicPath) {
      return null;
    }
    return uri;
  }

  static Future<bool> open(String raw) async {
    final uri = parse(raw);
    if (uri == null) return false;
    if (!isGhostEcosHost(uri.host)) {
      final confirmed = await _confirmExternalOpen(uri);
      if (confirmed == null) return false;
      // A deliberate cancellation is a handled action, not a launch failure.
      if (!confirmed) return true;
    }
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openDownload() async {
    final uri = Uri.parse('https://ghostecos.duckdns.org/download/latest');
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  static Future<bool?> _confirmExternalOpen(Uri uri) async {
    final context = appNavigatorKey.currentContext;
    if (context == null || !context.mounted) return null;
    return await showDialog<bool>(
          context: context,
          useRootNavigator: true,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Открыть внешнюю ссылку?'),
            content: Text(
              'Ссылка ведёт на ${uri.host}. GhostChat откроет её во внешнем приложении или браузере.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Открыть'),
              ),
            ],
          ),
        ) ??
        false;
  }
}
