import 'dart:io';

import 'package:flutter/services.dart';

enum AndroidUpdateDownloadPhase { downloading, completed, failed }

class AndroidUpdateDownloadState {
  final int downloadId;
  final String version;
  final AndroidUpdateDownloadPhase phase;
  final double? progress;
  final String? message;

  const AndroidUpdateDownloadState({
    required this.downloadId,
    required this.version,
    required this.phase,
    this.progress,
    this.message,
  });

  static AndroidUpdateDownloadState? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final id = int.tryParse('${raw['downloadId'] ?? ''}');
    final version = '${raw['version'] ?? ''}'.trim();
    final phase = switch ('${raw['phase'] ?? ''}') {
      'downloading' => AndroidUpdateDownloadPhase.downloading,
      'completed' => AndroidUpdateDownloadPhase.completed,
      'failed' => AndroidUpdateDownloadPhase.failed,
      _ => null,
    };
    if (id == null || id <= 0 || version.isEmpty || phase == null) return null;
    final rawProgress = raw['progress'];
    final progress = rawProgress is num
        ? rawProgress.toDouble().clamp(0.0, 1.0).toDouble()
        : double.tryParse('$rawProgress')?.clamp(0.0, 1.0).toDouble();
    final message = '${raw['message'] ?? ''}'.trim();
    return AndroidUpdateDownloadState(
      downloadId: id,
      version: version,
      phase: phase,
      progress: progress,
      message: message.isEmpty ? null : message,
    );
  }
}

/// Android's DownloadManager persists APK transfers across app process death.
/// The activity channel only handles enqueue, status, and installer handoff;
/// Android continues the transfer independently in the system service.
class AndroidUpdateDownload {
  AndroidUpdateDownload._();

  static const MethodChannel _channel = MethodChannel(
    'ghostchat/update_download',
  );

  static bool get isSupported => Platform.isAndroid;

  static Future<AndroidUpdateDownloadState?> state() async {
    if (!isSupported) return null;
    final raw = await _channel.invokeMethod<dynamic>('getState');
    return AndroidUpdateDownloadState.tryParse(raw);
  }

  static Future<AndroidUpdateDownloadState?> enqueue({
    required String url,
    required String version,
  }) async {
    if (!isSupported) return null;
    final raw = await _channel.invokeMethod<dynamic>('enqueue', {
      'url': url,
      'version': version,
    });
    return AndroidUpdateDownloadState.tryParse(raw);
  }

  static Future<void> openInstaller(int downloadId) async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('openInstaller', {
      'downloadId': downloadId,
    });
  }

  static Future<void> clear({int? downloadId}) async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('clear', {'downloadId': downloadId});
  }
}
