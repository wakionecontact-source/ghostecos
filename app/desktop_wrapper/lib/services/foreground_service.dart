// Foreground-сервис: держит процесс приложения ЖИВЫМ в фоне (персистентное
// уведомление «GhostChat — в сети»), чтобы WS-листенер и хук уведомлений
// продолжали работать когда приложение свёрнуто/закрыто. Без этого Android
// убивает процесс → уведомления о входящих не приходят.
//
// Сообщения-уведомления показывает NotificationService из ГЛАВНОГО изолята
// (он жив, пока держит сервис). TaskHandler ниже — минимальный keep-alive.
//
// Defensive: любой сбой не должен ронять приложение.
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// Top-level callback сервиса (отдельный изолят). Обязателен vm:entry-point.
@pragma('vm:entry-point')
void ghostForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_GhostTaskHandler());
}

class _GhostTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

class ForegroundService {
  ForegroundService._();
  static final ForegroundService instance = ForegroundService._();
  bool _inited = false;

  void init() {
    if (_inited || !Platform.isAndroid) return;
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'ghost_online',
          channelName: 'GhostChat в сети',
          channelDescription: 'Поддерживает связь для уведомлений',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(), // keep-alive, без таймера
          autoRunOnBoot: true, // автозапуск после перезагрузки телефона
          allowWakeLock: true,
        ),
      );
      _inited = true;
    } catch (e) {
      if (kDebugMode) print('[fg] init: $e');
    }
  }

  /// Запросить разрешения (уведомления + игнор оптимизации батареи) и запустить
  /// сервис с персистентным уведомлением. Идемпотентно.
  Future<void> start() async {
    try {
      init();
      // POST_NOTIFICATIONS (Android 13+) — без него сервис-уведомление не видно.
      final np = await FlutterForegroundTask.checkNotificationPermission();
      if (np != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      // Игнор оптимизации батареи — иначе Android усыпит сервис (Doze).
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        notificationTitle: 'GhostChat — в сети',
        notificationText: 'Поддерживаю связь для уведомлений',
        callback: ghostForegroundCallback,
      );
    } catch (e) {
      if (kDebugMode) print('[fg] start: $e');
    }
  }

  Future<void> stop() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      if (kDebugMode) print('[fg] stop: $e');
    }
  }
}
