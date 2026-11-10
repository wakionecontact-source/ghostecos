import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api/http_client.dart';
import '../core/app_version.dart';
import '../core/local/app_logger.dart';
import '../theme.dart';
import '../widgets/error_panel.dart';
import '../widgets/glass.dart';
import '../widgets/toast_overlay.dart';
import 'android_update_download.dart';
import 'bot_check_service.dart';
import 'ghost_asset_ota.dart';
import 'notification_service.dart';
import 'remote_settings_service.dart';

class UpdateException implements Exception {
  final String message;
  final String? details;

  const UpdateException(this.message, {this.details});

  @override
  String toString() => message;
}

class AppUpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final bool critical;
  final String title;
  final String notes;
  final List<String> whatsNew;
  final DateTime? releaseAt;

  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.critical,
    required this.title,
    required this.notes,
    required this.whatsNew,
    required this.releaseAt,
  });

  factory AppUpdateInfo.fromJson({
    required String currentVersion,
    required String latestVersion,
    required Map<String, dynamic> json,
  }) {
    final rawChanges = json['whats_new'] ?? json['whatsNew'];
    final changes = rawChanges is List
        ? rawChanges
              .map((item) => item.toString().trim())
              .where((item) => item.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    final rawRelease = '${json['release_at'] ?? ''}'.trim();
    return AppUpdateInfo(
      currentVersion: currentVersion,
      latestVersion: latestVersion,
      critical: json['critical'] == true,
      title: '${json['title'] ?? 'Обновление GhostChat'}'.trim(),
      notes: '${json['notes'] ?? ''}'.trim(),
      whatsNew: changes,
      releaseAt: DateTime.tryParse(rawRelease),
    );
  }
}

enum AppUpdatePhase {
  hidden,
  available,
  syncing,
  downloading,
  installing,
  readyToInstall,
  failed,
}

class AppUpdateUiState {
  final AppUpdateInfo? info;
  final AppUpdatePhase phase;
  final double? progress;
  final String? message;

  const AppUpdateUiState({
    this.info,
    this.phase = AppUpdatePhase.hidden,
    this.progress,
    this.message,
  });

  bool get isVisible => info != null && phase != AppUpdatePhase.hidden;
  bool get isBusy =>
      phase == AppUpdatePhase.syncing ||
      phase == AppUpdatePhase.downloading ||
      phase == AppUpdatePhase.installing;
}

/// Server-selected delivery path for clients using update protocol v2.
/// A missing plan means the server is using the legacy update response.
class AppUpdatePlan {
  final String recommended;
  final bool apkAvailable;
  final bool apkRequired;
  final bool otaEligible;
  final bool otaAvailable;
  final String baseVersion;

  const AppUpdatePlan({
    required this.recommended,
    required this.apkAvailable,
    required this.apkRequired,
    required this.otaEligible,
    required this.otaAvailable,
    required this.baseVersion,
  });

  static AppUpdatePlan? tryParse(dynamic raw) {
    if (raw is! Map || raw['protocol'] != 2) return null;
    final apk = raw['apk'];
    final ota = raw['ota'];
    if (apk is! Map || ota is! Map) return null;
    final recommended = '${raw['recommended'] ?? ''}'.trim();
    if (!const {'apk', 'ota', 'none'}.contains(recommended)) return null;
    return AppUpdatePlan(
      recommended: recommended,
      apkAvailable: apk['available'] == true,
      apkRequired: apk['required'] == true,
      otaEligible: ota['eligible'] == true,
      otaAvailable: ota['available'] == true,
      baseVersion: '${ota['base_version'] ?? ''}'.trim(),
    );
  }
}

class AppUpdateCheckResult {
  final String currentVersion;
  final String latestVersion;
  final AppUpdateInfo? update;
  final AppUpdatePlan? plan;

  const AppUpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    this.update,
    this.plan,
  });

  bool get updateAvailable => update != null;
}

/// Проверяет релиз при входе в приложение и на каждом возвращении из фона.
/// Пока процесс приложения жив, периодический таймер позволяет показать
/// локальное Android-уведомление даже в фоне; запуск установки всегда идёт
/// через системный APK-инсталлятор Android.
class UpdateService with WidgetsBindingObserver {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const _snoozeKey = 'app_update_snooze_until';
  static const _skipKey = 'app_update_skip_until';
  static const _checksEnabledKey = 'app_update_checks_enabled_v1';
  static const _checkInterval = Duration(minutes: 15);
  static const _resumeDebounce = Duration(seconds: 45);

  Timer? _timer;
  Timer? _androidDownloadPollTimer;
  Future<void>? _checkInFlight;
  DateTime? _lastCheck;
  DateTime? _snoozeUntil;
  DateTime? _skipUntil;
  AppUpdateInfo? _pending;
  final ValueNotifier<AppUpdateUiState> uiState = ValueNotifier(
    const AppUpdateUiState(),
  );
  String? _shownVersion;
  String? _notifiedVersion;
  bool _downloadInFlight = false;
  bool _androidDownloadPollInFlight = false;
  bool _androidRestoreInFlight = false;
  bool _installerHandoffInFlight = false;
  bool _installerOpened = false;
  bool _started = false;
  bool _checksEnabled = true;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  AppUpdateInfo? get pending => _pending;
  bool get checksEnabled => _checksEnabled;

  Future<void> loadSettings() => _loadSuppression();

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _lifecycle =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    await _loadSuppression();
    unawaited(checkNow());
    if (AndroidUpdateDownload.isSupported) {
      unawaited(_restoreAndroidDownload());
    }
    if (_lifecycle == AppLifecycleState.resumed) _startTimer();
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _stopTimer();
    _stopAndroidDownloadPolling();
    _pending = null;
    uiState.value = const AppUpdateUiState();
    _shownVersion = null;
    _notifiedVersion = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (state == AppLifecycleState.resumed) {
      _startTimer();
      if (_installerOpened) {
        _installerOpened = false;
        _lastCheck = null;
        unawaited(_resumeUpdateState(forceCheck: true));
        return;
      }
      unawaited(_resumeUpdateState());
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Проверка обновлений не должна будить сеть каждые 15 минут, пока
      // приложение свёрнуто. При возврате в foreground проверим сразу.
      _stopTimer();
    }
  }

  Future<void> _resumeUpdateState({bool forceCheck = false}) async {
    if (forceCheck) {
      await checkNow(force: true);
    } else {
      await checkNow();
    }
    if (AndroidUpdateDownload.isSupported) {
      await _restoreAndroidDownload();
    }
  }

  void _startTimer() {
    if (!_started || _timer != null) return;
    _timer = Timer.periodic(_checkInterval, (_) {
      unawaited(checkNow());
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _loadSuppression() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _snoozeUntil = _dateFromMillis(prefs.getInt(_snoozeKey));
      _skipUntil = _dateFromMillis(prefs.getInt(_skipKey));
      _checksEnabled = prefs.getBool(_checksEnabledKey) ?? true;
    } catch (error) {
      appLog.warn('update', 'suppression preferences unavailable: $error');
    }
  }

  DateTime? _dateFromMillis(int? value) =>
      value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);

  Future<void> checkNow({bool force = false}) async {
    if (!_started && !force) return;
    if (!_checksEnabled && !force) return;
    final now = DateTime.now();
    // «Пропустить на час» — это именно пауза проверки, а не только скрытие
    // окна. Проверяем до force, чтобы перезапуск приложения и возврат из фона
    // также не отправляли запросы к /api/version в течение этого часа.
    if (_skipUntil?.isAfter(now) == true) return;
    final running = _checkInFlight;
    if (running != null) return running;
    if (!force &&
        _lastCheck != null &&
        now.difference(_lastCheck!) < _resumeDebounce) {
      return;
    }
    _lastCheck = now;
    final future = _checkInternal();
    _checkInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_checkInFlight, future)) _checkInFlight = null;
    }
  }

  Future<void> setChecksEnabled(bool enabled) async {
    _checksEnabled = enabled;
    if (!enabled) {
      _pending = null;
      uiState.value = const AppUpdateUiState();
      _shownVersion = null;
      _notifiedVersion = null;
      _lastCheck = null;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_checksEnabledKey, enabled);
    } catch (error) {
      appLog.warn('update', 'could not save update-check setting: $error');
    }
  }

  Future<String> currentVersion() => _currentVersion();

  /// A user-facing check keeps the current version even when the server says
  /// that there is no update. Automatic checks intentionally keep using
  /// [_fetchInfo], which only returns actionable updates.
  Future<AppUpdateCheckResult> checkStatus() async {
    final current = await _currentVersion();
    try {
      final response = await HttpClient.I.dio.get(
        '/api/version',
        options: Options(
          extra: const {'skipAuth': true},
          responseType: ResponseType.json,
          headers: const {'Cache-Control': 'no-store'},
        ),
      );
      if (response.statusCode != 200 || response.data is! Map) {
        throw const UpdateException('Сервер вернул некорректный ответ');
      }
      final overview = Map<String, dynamic>.from(response.data as Map);
      final plan = AppUpdatePlan.tryParse(overview['update_plan']);
      final latest = '${overview['latest'] ?? ''}'.trim();
      if (overview['available'] == false || latest.isEmpty) {
        _pending = null;
        uiState.value = const AppUpdateUiState();
        return AppUpdateCheckResult(
          currentVersion: current,
          latestVersion: current,
          plan: plan,
        );
      }
      if (plan != null && plan.recommended != 'apk') {
        _pending = null;
        uiState.value = const AppUpdateUiState();
        return AppUpdateCheckResult(
          currentVersion: current,
          latestVersion: latest,
          plan: plan,
        );
      }
      if (latest == current) {
        _pending = null;
        uiState.value = const AppUpdateUiState();
        return AppUpdateCheckResult(
          currentVersion: current,
          latestVersion: latest,
          plan: plan,
        );
      }

      Map<String, dynamic> details = overview;
      try {
        final detailResponse = await HttpClient.I.dio.get(
          '/api/version/${Uri.encodeComponent(latest)}',
          options: Options(
            extra: const {'skipAuth': true},
            responseType: ResponseType.json,
            headers: const {'Cache-Control': 'no-store'},
          ),
        );
        if (detailResponse.statusCode == 200 && detailResponse.data is Map) {
          details = Map<String, dynamic>.from(detailResponse.data as Map);
        }
      } catch (error) {
        appLog.warn('update', 'release notes request failed: $error');
      }
      final info = AppUpdateInfo.fromJson(
        currentVersion: current,
        latestVersion: latest,
        json: details,
      );
      _pending = info;
      uiState.value = AppUpdateUiState(
        info: info,
        phase: AppUpdatePhase.available,
      );
      _lastCheck = DateTime.now();
      return AppUpdateCheckResult(
        currentVersion: current,
        latestVersion: latest,
        update: info,
        plan: plan,
      );
    } catch (error) {
      if (error is UpdateException) rethrow;
      throw UpdateException(
        'Не удалось проверить обновления',
        details: '$error',
      );
    }
  }

  Future<void> _checkInternal() async {
    try {
      final info = await _fetchInfo();
      if (!_checksEnabled) {
        _pending = null;
        uiState.value = const AppUpdateUiState();
        return;
      }
      if (info == null) {
        _pending = null;
        _stopAndroidDownloadPolling();
        uiState.value = const AppUpdateUiState();
        return;
      }
      final currentUi = uiState.value;
      if (currentUi.info?.latestVersion == info.latestVersion &&
          (currentUi.phase == AppUpdatePhase.downloading ||
              currentUi.phase == AppUpdatePhase.installing ||
              currentUi.phase == AppUpdatePhase.readyToInstall ||
              currentUi.phase == AppUpdatePhase.failed)) {
        _pending = info;
        return;
      }
      _pending = info;
      uiState.value = AppUpdateUiState(
        info: info,
        phase: AppUpdatePhase.available,
      );
      if (_lifecycle != AppLifecycleState.resumed) {
        _notifyInBackground(info);
      }
    } catch (error, stack) {
      appLog.warn('update', 'version check failed: $error');
      appLog.debug('update', '$stack');
    }
  }

  Future<AppUpdateInfo?> _fetchInfo() async {
    final current = await _currentVersion();
    final response = await HttpClient.I.dio.get(
      '/api/version',
      options: Options(
        extra: const {'skipAuth': true},
        responseType: ResponseType.json,
        headers: const {'Cache-Control': 'no-store'},
      ),
    );
    if (response.statusCode != 200 || response.data is! Map) return null;
    final overview = Map<String, dynamic>.from(response.data as Map);
    if (overview['available'] == false) return null;
    final plan = AppUpdatePlan.tryParse(overview['update_plan']);
    if (plan != null &&
        (plan.recommended != 'apk' ||
            !plan.apkRequired ||
            !plan.apkAvailable)) {
      _pending = null;
      return null;
    }
    final latest = '${overview['latest'] ?? ''}'.trim();
    if (latest.isEmpty || latest == current) return null;

    Map<String, dynamic> details = overview;
    try {
      final detailResponse = await HttpClient.I.dio.get(
        '/api/version/${Uri.encodeComponent(latest)}',
        options: Options(
          extra: const {'skipAuth': true},
          responseType: ResponseType.json,
          headers: const {'Cache-Control': 'no-store'},
        ),
      );
      if (detailResponse.statusCode == 200 && detailResponse.data is Map) {
        details = Map<String, dynamic>.from(detailResponse.data as Map);
      }
    } catch (error) {
      // A version mismatch is still useful when the optional release notes
      // endpoint is temporarily unavailable.
      appLog.warn('update', 'release notes request failed: $error');
    }
    return AppUpdateInfo.fromJson(
      currentVersion: current,
      latestVersion: latest,
      json: details,
    );
  }

  Future<void> _restoreAndroidDownload() async {
    if (!AndroidUpdateDownload.isSupported || _androidRestoreInFlight) return;
    _androidRestoreInFlight = true;
    try {
      final state = await AndroidUpdateDownload.state();
      if (state == null) return;

      final current = await _currentVersion();
      if (state.version == current) {
        await AndroidUpdateDownload.clear(downloadId: state.downloadId);
        _stopAndroidDownloadPolling();
        _pending = null;
        uiState.value = const AppUpdateUiState();
        return;
      }

      final checkInFlight = _checkInFlight;
      if (_pending == null && checkInFlight != null) await checkInFlight;
      var info = _pending;
      if (info == null) {
        await checkNow(force: true);
        info = _pending;
      }
      if (info != null && info.latestVersion != state.version) {
        await AndroidUpdateDownload.clear(downloadId: state.downloadId);
        _stopAndroidDownloadPolling();
        _pending = info;
        uiState.value = AppUpdateUiState(
          info: info,
          phase: AppUpdatePhase.available,
        );
        return;
      }
      info ??= AppUpdateInfo(
        currentVersion: current,
        latestVersion: state.version,
        critical: false,
        title: 'Обновление GhostChat',
        notes: '',
        whatsNew: const [],
        releaseAt: null,
      );
      _pending = info;

      switch (state.phase) {
        case AndroidUpdateDownloadPhase.downloading:
          uiState.value = AppUpdateUiState(
            info: info,
            phase: AppUpdatePhase.downloading,
            progress: state.progress,
          );
          _startAndroidDownloadPolling(info);
        case AndroidUpdateDownloadPhase.completed:
          _stopAndroidDownloadPolling();
          uiState.value = AppUpdateUiState(
            info: info,
            phase: AppUpdatePhase.readyToInstall,
            progress: 1,
          );
        case AndroidUpdateDownloadPhase.failed:
          _stopAndroidDownloadPolling();
          uiState.value = AppUpdateUiState(
            info: info,
            phase: AppUpdatePhase.failed,
            message: state.message ?? 'Не удалось скачать обновление',
          );
      }
    } catch (error, stack) {
      appLog.warn('update', 'Android download restore failed: $error');
      appLog.debug('update', '$stack');
    } finally {
      _androidRestoreInFlight = false;
    }
  }

  void _startAndroidDownloadPolling(
    AppUpdateInfo info, {
    ValueChanged<double>? onProgress,
  }) {
    if (_androidDownloadPollTimer != null) return;
    _androidDownloadPollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_pollAndroidDownload(info, onProgress: onProgress)),
    );
    unawaited(_pollAndroidDownload(info, onProgress: onProgress));
  }

  void _stopAndroidDownloadPolling() {
    _androidDownloadPollTimer?.cancel();
    _androidDownloadPollTimer = null;
  }

  Future<void> _pollAndroidDownload(
    AppUpdateInfo info, {
    ValueChanged<double>? onProgress,
  }) async {
    if (_androidDownloadPollInFlight) return;
    _androidDownloadPollInFlight = true;
    try {
      final state = await AndroidUpdateDownload.state();
      if (state == null || state.version != info.latestVersion) {
        _stopAndroidDownloadPolling();
        return;
      }
      switch (state.phase) {
        case AndroidUpdateDownloadPhase.downloading:
          uiState.value = AppUpdateUiState(
            info: info,
            phase: AppUpdatePhase.downloading,
            progress: state.progress,
          );
          if (state.progress != null) onProgress?.call(state.progress!);
        case AndroidUpdateDownloadPhase.completed:
          _stopAndroidDownloadPolling();
          if (_lifecycle == AppLifecycleState.resumed) {
            await _installAndroidDownload(info, state);
          } else {
            uiState.value = AppUpdateUiState(
              info: info,
              phase: AppUpdatePhase.readyToInstall,
              progress: 1,
            );
          }
        case AndroidUpdateDownloadPhase.failed:
          _stopAndroidDownloadPolling();
          uiState.value = AppUpdateUiState(
            info: info,
            phase: AppUpdatePhase.failed,
            message: state.message ?? 'Не удалось скачать обновление',
          );
      }
    } catch (error, stack) {
      appLog.warn('update', 'Android download status failed: $error');
      appLog.debug('update', '$stack');
    } finally {
      _androidDownloadPollInFlight = false;
    }
  }

  Future<void> _installAndroidDownload(
    AppUpdateInfo info,
    AndroidUpdateDownloadState state,
  ) async {
    if (_installerHandoffInFlight) return;
    _installerHandoffInFlight = true;
    uiState.value = AppUpdateUiState(
      info: info,
      phase: AppUpdatePhase.syncing,
      progress: 1,
      message: 'Применяем настройки и ассеты…',
    );
    try {
      await RemoteSettingsService.instance.refresh();
      await GhostAssetOta.instance.refresh();
      uiState.value = AppUpdateUiState(
        info: info,
        phase: AppUpdatePhase.installing,
        progress: 1,
        message: 'Открываем системный установщик…',
      );
      await AndroidUpdateDownload.openInstaller(state.downloadId);
      _installerOpened = true;
      _lastCheck = null;
      await NotificationService.instance.clearUpdateNotifications();
      appLog.info(
        'update',
        'Android DownloadManager APK opened for installation version=${info.latestVersion}',
      );
    } catch (error) {
      uiState.value = AppUpdateUiState(
        info: info,
        phase: AppUpdatePhase.readyToInstall,
        progress: 1,
        message: error.toString(),
      );
      appLog.warn('update', 'Android installer handoff failed: $error');
    } finally {
      _installerHandoffInFlight = false;
    }
  }

  Future<void> _refreshInternalUpdates() async {
    await RemoteSettingsService.instance.refresh();
    await GhostAssetOta.instance.refresh();
  }

  Future<String> _currentVersion() => GhostChatAppVersion.current();

  bool _suppressed(AppUpdateInfo info) {
    final now = DateTime.now();
    if (_snoozeUntil?.isAfter(now) == true) return true;
    if (!info.critical && _skipUntil?.isAfter(now) == true) return true;
    return false;
  }

  void _notifyInBackground(AppUpdateInfo info) {
    if (_suppressed(info) || _notifiedVersion == info.latestVersion) return;
    _notifiedVersion = info.latestVersion;
    unawaited(
      NotificationService.instance.showUpdateAvailable(
        version: info.latestVersion,
        critical: info.critical,
      ),
    );
  }

  /// Called by NotificationService when the user taps the update notification.
  Future<void> openPendingUpdate() async {
    // A notification tap is explicit user intent, so the update details page
    // can be opened. Routine foreground checks only reveal the sidebar button.
    var info = _pending;
    if (info == null) {
      try {
        info = await _fetchInfo();
      } catch (error) {
        appLog.warn('update', 'notification update fetch failed: $error');
      }
    }
    if (info == null) return;
    _pending = info;
    uiState.value = AppUpdateUiState(
      info: info,
      phase: AppUpdatePhase.available,
    );
    _shownVersion = null;
    _present(info, ignoreSuppression: true);
  }

  void _present(AppUpdateInfo info, {required bool ignoreSuppression}) {
    if (!ignoreSuppression && _suppressed(info)) return;
    final navigator = NotificationService.navigatorKey.currentState;
    if (navigator == null) return;
    if (_shownVersion == info.latestVersion && !ignoreSuppression) return;
    _shownVersion = info.latestVersion;
    navigator.push(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (_, __, ___) => UpdateScreen(info: info),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  Future<void> snooze(AppUpdateInfo info) async {
    final until = DateTime.now().add(const Duration(minutes: 25));
    _snoozeUntil = until;
    _shownVersion = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_snoozeKey, until.millisecondsSinceEpoch);
    } catch (error) {
      appLog.warn('update', 'could not save 25m snooze: $error');
    }
  }

  Future<void> skipForHour(AppUpdateInfo info) async {
    final until = DateTime.now().add(const Duration(hours: 1));
    _skipUntil = until;
    _snoozeUntil = null;
    _shownVersion = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_skipKey, until.millisecondsSinceEpoch);
      await prefs.remove(_snoozeKey);
    } catch (error) {
      appLog.warn('update', 'could not save 1h skip: $error');
    }
  }

  Future<void> downloadAndOpen(
    BuildContext context,
    AppUpdateInfo info, {
    ValueChanged<double>? onProgress,
  }) async {
    if (_downloadInFlight) return;
    if (AndroidUpdateDownload.isSupported) {
      final existing = await AndroidUpdateDownload.state();
      if (existing?.phase == AndroidUpdateDownloadPhase.completed &&
          existing?.version == info.latestVersion) {
        await _installAndroidDownload(info, existing!);
        return;
      }
    }
    if (!context.mounted) return;
    _downloadInFlight = true;
    _pending = info;
    uiState.value = AppUpdateUiState(info: info, phase: AppUpdatePhase.syncing);
    try {
      final token = await BotCheckService.instance.ensureToken(
        context,
        purpose: 'download',
      );

      if (AndroidUpdateDownload.isSupported) {
        final response = await HttpClient.I.dio.post(
          '/api/download/update-ticket',
          data: {'version': info.latestVersion},
          options: Options(
            extra: const {'skipAuth': true},
            headers: {'X-Ghost-Bot-Token': token, 'Cache-Control': 'no-store'},
            responseType: ResponseType.json,
            receiveTimeout: const Duration(seconds: 30),
          ),
        );
        final body = response.data is Map
            ? Map<String, dynamic>.from(response.data as Map)
            : const <String, dynamic>{};
        final downloadPath = '${body['download_url'] ?? ''}'.trim();
        if ((response.statusCode ?? 0) != 200 || downloadPath.isEmpty) {
          BotCheckService.instance.clear('download');
          throw UpdateException(
            _responseMessage(body, 'Скачивание обновления недоступно'),
          );
        }
        final baseUri = Uri.parse(HttpClient.I.dio.options.baseUrl);
        final downloadUri = baseUri.resolve(downloadPath);
        if (downloadUri.scheme != 'https') {
          throw const UpdateException('Ссылка на обновление не защищена HTTPS');
        }
        final state = await AndroidUpdateDownload.enqueue(
          url: downloadUri.toString(),
          version: info.latestVersion,
        );
        if (state == null) {
          throw const UpdateException('Android не принял загрузку обновления');
        }
        _pending = info;
        uiState.value = AppUpdateUiState(
          info: info,
          phase: switch (state.phase) {
            AndroidUpdateDownloadPhase.downloading =>
              AppUpdatePhase.downloading,
            AndroidUpdateDownloadPhase.completed =>
              AppUpdatePhase.readyToInstall,
            AndroidUpdateDownloadPhase.failed => AppUpdatePhase.failed,
          },
          progress: state.progress,
          message: state.message,
        );
        if (state.phase == AndroidUpdateDownloadPhase.downloading) {
          _startAndroidDownloadPolling(info, onProgress: onProgress);
        } else if (state.phase == AndroidUpdateDownloadPhase.completed) {
          await _installAndroidDownload(info, state);
        }
        return;
      }

      final temp = await getTemporaryDirectory();
      final safeVersion = info.latestVersion.replaceAll(
        RegExp(r'[^0-9A-Za-z._-]'),
        '_',
      );
      final file = File('${temp.path}/GhostChat_V${safeVersion}ob.apk');
      uiState.value = AppUpdateUiState(
        info: info,
        phase: AppUpdatePhase.downloading,
      );
      final response = await HttpClient.I.dio.download(
        '/api/download/update',
        file.path,
        data: {'version': info.latestVersion},
        options: Options(
          method: 'POST',
          extra: const {'skipAuth': true},
          headers: {'X-Ghost-Bot-Token': token, 'Cache-Control': 'no-store'},
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(minutes: 5),
        ),
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final progress = (received / total).clamp(0.0, 1.0).toDouble();
            uiState.value = AppUpdateUiState(
              info: info,
              phase: AppUpdatePhase.downloading,
              progress: progress,
            );
            onProgress?.call(progress);
          }
        },
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        BotCheckService.instance.clear('download');
        throw UpdateException(
          _responseMessage(response.data, 'Скачивание обновления недоступно'),
        );
      }
      if (!await file.exists() || await file.length() < 1024) {
        throw const UpdateException('Сервер прислал неполный APK');
      }
      await _refreshInternalUpdates();
      uiState.value = AppUpdateUiState(
        info: info,
        phase: AppUpdatePhase.installing,
        progress: 1,
        message: 'Открываем установщик…',
      );
      final result = await OpenFilex.open(
        file.path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) {
        throw UpdateException(
          'Не удалось открыть установщик Android',
          details: result.message,
        );
      }
      _installerOpened = true;
      _lastCheck = null;
      uiState.value = AppUpdateUiState(
        info: info,
        phase: AppUpdatePhase.installing,
        progress: 1,
        message: 'Ожидаем завершения установки',
      );
      await NotificationService.instance.clearUpdateNotifications();
      appLog.info(
        'update',
        'APK opened for installation version=${info.latestVersion}',
      );
    } on UpdateException catch (error) {
      uiState.value = AppUpdateUiState(
        info: info,
        phase: AppUpdatePhase.failed,
        message: error.message,
      );
      rethrow;
    } on DioException catch (error) {
      BotCheckService.instance.clear('download');
      final failure = UpdateException(
        'Не удалось скачать обновление',
        details: error.response?.data?.toString() ?? error.message,
      );
      uiState.value = AppUpdateUiState(
        info: info,
        phase: AppUpdatePhase.failed,
        message: failure.message,
      );
      throw failure;
    } catch (error) {
      final failure = UpdateException(
        'Не удалось установить обновление',
        details: '$error',
      );
      uiState.value = AppUpdateUiState(
        info: info,
        phase: AppUpdatePhase.failed,
        message: failure.message,
      );
      throw failure;
    } finally {
      _downloadInFlight = false;
      // Keep the APK while the system installer is using it. Temporary files
      // are cleaned by Android; deleting here would break the installer.
    }
  }

  String _responseMessage(dynamic data, String fallback) {
    if (data is Map && data['detail'] != null) {
      final detail = data['detail'];
      if (detail is Map && detail['message'] != null) {
        return detail['message'].toString();
      }
      return detail.toString();
    }
    return fallback;
  }
}

class UpdateScreen extends StatefulWidget {
  final AppUpdateInfo info;

  const UpdateScreen({super.key, required this.info});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  bool _busy = false;
  double _progress = 0;
  String? _error;
  String? _errorDetails;
  int? _errorLogId;

  Color get _accent => widget.info.critical ? GE.red : GE.primary;

  Future<void> _install() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
      _errorDetails = null;
      _errorLogId = null;
    });
    try {
      await UpdateService.instance.downloadAndOpen(
        context,
        widget.info,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value.clamp(0, 1));
        },
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      final entry = appLog.error('update', '$error');
      if (!mounted) return;
      setState(() {
        _error = error is UpdateException
            ? error.message
            : 'Не удалось скачать обновление';
        _errorDetails = error is UpdateException ? error.details : '$error';
        _errorLogId = entry.id;
        _busy = false;
      });
      toast.show('Ошибка обновления', level: ToastLevel.error, logId: entry.id);
    }
  }

  Future<void> _snooze() async {
    await UpdateService.instance.snooze(widget.info);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _skip() async {
    await UpdateService.instance.skipForHour(widget.info);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Color.alphaBlend(
          GE.shadow.withValues(alpha: 0.64),
          GE.bgDeep,
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500),
                child: GlassCard(
                  strong: true,
                  radius: GE.radiusLg,
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _accent.withValues(alpha: 0.16),
                          border: Border.all(
                            color: _accent.withValues(alpha: 0.42),
                          ),
                        ),
                        child: Icon(
                          info.critical
                              ? Icons.warning_amber_rounded
                              : Icons.system_update_alt_rounded,
                          color: _accent,
                          size: 32,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        info.critical
                            ? 'Критическое обновление'
                            : 'Доступно обновление',
                        style: TextStyle(
                          color: GE.text,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        info.title,
                        style: TextStyle(color: _accent, fontSize: 14),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: _versionChip('Сейчас', info.currentVersion),
                          ),
                          const SizedBox(width: 10),
                          Icon(Icons.arrow_forward_rounded, color: _accent),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _versionChip('Новая', info.latestVersion),
                          ),
                        ],
                      ),
                      if (info.notes.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Text(
                          info.notes,
                          style: TextStyle(color: GE.sub, height: 1.4),
                        ),
                      ],
                      if (info.whatsNew.isNotEmpty) ...[
                        const SizedBox(height: 18),
                        Text(
                          'Что нового',
                          style: TextStyle(
                            color: GE.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        for (final item in info.whatsNew)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 7),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('•  ', style: TextStyle(color: _accent)),
                                Expanded(
                                  child: Text(
                                    item,
                                    style: TextStyle(
                                      color: GE.sub,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 10),
                        AppErrorPanel(
                          title: 'Ошибка обновления',
                          message: _error!,
                          details: _errorDetails,
                          logId: _errorLogId,
                          compact: true,
                          onRetry: _install,
                        ),
                      ],
                      if (_busy) ...[
                        const SizedBox(height: 18),
                        LinearProgressIndicator(
                          value: _progress > 0 ? _progress : null,
                          color: _accent,
                          backgroundColor: GE.border,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _progress > 0
                              ? 'Скачивание ${(100 * _progress).round()}%'
                              : 'Проверка CAPTCHA и подготовка APK…',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: GE.sub, fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 22),
                      GlassButton(
                        label: _busy ? 'Скачивание…' : 'Скачать и установить',
                        icon: Icons.download_rounded,
                        primary: true,
                        fullWidth: true,
                        onTap: _busy ? null : _install,
                      ),
                      const SizedBox(height: 10),
                      GlassButton(
                        label: info.critical
                            ? 'Напомнить через 25 минут'
                            : 'Попозже · 25 минут',
                        fullWidth: true,
                        onTap: _busy ? null : _snooze,
                      ),
                      if (!info.critical) ...[
                        const SizedBox(height: 4),
                        TextButton(
                          onPressed: _busy ? null : _skip,
                          child: Text(
                            'Пропустить на 1 час',
                            style: TextStyle(color: GE.sub),
                          ),
                        ),
                      ],
                      const SizedBox(height: 5),
                      Text(
                        'После скачивания Android сам откроет окно «Обновить?».',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: GE.muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _versionChip(String label, String version) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: GE.surface.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(GE.radiusSm),
        border: Border.all(color: GE.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: GE.muted, fontSize: 11)),
          const SizedBox(height: 3),
          Text(
            version,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: GE.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
