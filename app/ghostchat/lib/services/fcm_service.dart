// FCM generic-push отключён: Android сам показывал его поверх настроенного
// локального уведомления GhostChat, из-за чего каждое сообщение дублировалось.
// Локальные уведомления и foreground-сервис приложения продолжают работать.
//
// Defensive: всё в try/catch — сбой FCM не должен ронять приложение.
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

// Фоновый обработчик (отдельный изолят, обязателен top-level + vm:entry-point).
// Сообщение-уведомление Android покажет САМ из notification-payload сервера.
// Здесь ничего тяжёлого не делаем (нет доступа к main-изоляту/ключам).
@pragma('vm:entry-point')
Future<void> firebaseBgHandler(RemoteMessage message) async {
  // no-op: показ берёт на себя Android (generic notification от сервера),
  // реальную синхронизацию сделает fetchPending когда юзер откроет приложение.
}

class FcmService {
  FcmService._();
  static final FcmService instance = FcmService._();
  bool _inited = false;

  Future<void> init() async {
    if (!Platform.isAndroid || _inited) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseBgHandler);
      _inited = true;
    } catch (e) {
      if (kDebugMode) print('[fcm] init: $e');
    }
  }

  /// Отключить generic-push от FCM и удалить ранее выданный токен. Это нужно
  /// делать и для обновления поверх старой версии: иначе старый токен ещё мог
  /// получать системное уведомление Android.
  Future<void> disableGenericPush() async {
    if (!Platform.isAndroid) return;
    try {
      await init();
      final fm = FirebaseMessaging.instance;
      await fm.setAutoInitEnabled(false);
      await fm.deleteToken();
    } catch (e) {
      if (kDebugMode) print('[fcm] disable generic push: $e');
    }
  }
}
