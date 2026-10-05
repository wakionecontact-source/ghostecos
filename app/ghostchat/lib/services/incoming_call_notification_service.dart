import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class IncomingCallNotificationService with WidgetsBindingObserver {
  IncomingCallNotificationService._();

  static final instance = IncomingCallNotificationService._();
  static const _notificationId = 7301;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  bool _appIsForeground = true;

  Future<void> initialize() async {
    if (!Platform.isAndroid || _initialized) return;
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    WidgetsBinding.instance.addObserver(this);
    _initialized = true;
  }

  Future<bool?> requestPermission() async {
    if (!Platform.isAndroid || !_initialized) return true;
    return _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  Future<void> showIncomingCall({
    required String callId,
    required String from,
    required bool video,
  }) async {
    if (!Platform.isAndroid || !_initialized || _appIsForeground) return;
    await _plugin.show(
      _notificationId,
      'Входящий ${video ? 'видеозвонок' : 'звонок'}',
      'Звонит @$from',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'ghost_calls_incoming_v2',
          'Входящие звонки',
          channelDescription: 'Оповещения о входящих звонках Ghost Calls',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          visibility: NotificationVisibility.public,
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
          playSound: true,
          enableVibration: true,
          ongoing: true,
          autoCancel: false,
          ticker: 'Входящий звонок',
        ),
      ),
      payload: callId,
    );
  }

  Future<void> clearIncomingCall() async {
    if (!Platform.isAndroid || !_initialized) return;
    await _plugin.cancel(_notificationId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsForeground = state == AppLifecycleState.resumed;
  }
}
