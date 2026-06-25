// FCM (Firebase Cloud Messaging) — надёжный wake-сигнал для уведомлений, который
// MIUI/Doze НЕ блокирует (доставляется через Google Play Services, системно).
//
// ПРИВАТНОСТЬ (E2E): сам push НЕ содержит текста сообщения. Сервер шлёт лишь
// generic-уведомление («Новое сообщение») + data-сигнал. Реальное сообщение
// приложение тянет по своему E2E-каналу (fetchPending → расшифровка локально)
// при открытии/в foreground. Текст переписки через Google НЕ идёт.
//
// Defensive: всё в try/catch — сбой FCM не должен ронять приложение.
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'chat_repo.dart';

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

  /// Запросить разрешение, получить токен, зарегистрировать на сервере. Зовём
  /// после логина. На рефреш токена — перерегистрируем.
  Future<void> registerToken() async {
    if (!Platform.isAndroid) return;
    try {
      await init();
      final fm = FirebaseMessaging.instance;
      await fm.requestPermission();
      final token = await fm.getToken();
      if (token != null && token.isNotEmpty) {
        await ChatRepo.instance.registerFcmToken(token);
      }
      fm.onTokenRefresh.listen((t) {
        ChatRepo.instance.registerFcmToken(t);
      });
      // Push пришёл с приложением на переднем плане → синхронизируемся.
      FirebaseMessaging.onMessage.listen((_) => _syncPending());
      // Юзер тапнул по уведомлению, приложение открылось → синхронизируемся.
      FirebaseMessaging.onMessageOpenedApp.listen((_) => _syncPending());
    } catch (e) {
      if (kDebugMode) print('[fcm] register: $e');
    }
  }

  void _syncPending() {
    // Wake → тянем накопленное по E2E-каналу (расшифровка локально → уведомление
    // покажет существующий хук в _ingestIncoming/_ingestV2).
    ChatRepo.instance.fetchPending();
    ChatRepo.instance.fetchPendingSealed();
    ChatRepo.instance.fetchPendingV2();
  }
}
