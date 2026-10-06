import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'chat_organization_store.dart';

class IncomingCallNotificationService with WidgetsBindingObserver {
  IncomingCallNotificationService._();

  static final instance = IncomingCallNotificationService._();
  static const _notificationId = 7301;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  bool _appIsForeground = true;
  String? _currentCaller;

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
    if (ChatOrganizationStore.instance.isChatProtected(from)) {
      await clearIncomingCall();
      return;
    }
    _currentCaller = from;
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
    _currentCaller = null;
    await _plugin.cancel(_notificationId);
  }

  Future<void> clearIfCallerProtected() async {
    final caller = _currentCaller;
    if (caller != null &&
        ChatOrganizationStore.instance.isChatProtected(caller)) {
      await clearIncomingCall();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsForeground = state == AppLifecycleState.resumed;
  }
}
