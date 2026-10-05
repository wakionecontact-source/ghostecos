// Настройки уведомлений — перенесено из 1.19.3 (core/app_settings.dart):
// общий тумблер + "исключения" (замьюченные чаты) + отдельно тумблеры
// внутренних (in-app toast) уведомлений по уровням. Персист —
// SharedPreferences, тот же паттерн, что NavBarSettings/ThemeService.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationSettings {
  NotificationSettings._();
  static final NotificationSettings instance = NotificationSettings._();

  static const _kEnabledKey = 'notif_enabled_v1';
  static const _kMutedPeersKey = 'notif_muted_peers_v1';
  static const _kToastEnabledKey = 'notif_toast_enabled_v1';
  static const _kToastErrorsKey = 'notif_toast_errors_v1';
  static const _kToastWarningsKey = 'notif_toast_warnings_v1';
  static const _kToastInfoKey = 'notif_toast_info_v1';
  static const _kShowSenderKey = 'notif_show_sender_v1';
  static const _kShowContentKey = 'notif_show_content_v1';
  static const _kShowMediaPreviewKey = 'notif_show_media_preview_v1';

  /// Системные push/локальные уведомления о новых сообщениях — общий выключатель.
  final ValueNotifier<bool> enabledNotifier = ValueNotifier(true);

  /// Чаты, для которых уведомления не показываются, даже при enabledNotifier=true.
  final ValueNotifier<Set<String>> mutedPeersNotifier = ValueNotifier(
    <String>{},
  );

  /// Внутренние (in-app) тосты — отдельная категория от системных push.
  final ValueNotifier<bool> toastEnabledNotifier = ValueNotifier(true);
  final ValueNotifier<bool> toastShowErrorsNotifier = ValueNotifier(true);
  final ValueNotifier<bool> toastShowWarningsNotifier = ValueNotifier(true);
  final ValueNotifier<bool> toastShowInfoNotifier = ValueNotifier(true);
  final ValueNotifier<bool> showSenderNotifier = ValueNotifier(true);
  final ValueNotifier<bool> showContentNotifier = ValueNotifier(true);
  final ValueNotifier<bool> showMediaPreviewNotifier = ValueNotifier(true);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    enabledNotifier.value = prefs.getBool(_kEnabledKey) ?? true;
    toastEnabledNotifier.value = prefs.getBool(_kToastEnabledKey) ?? true;
    toastShowErrorsNotifier.value = prefs.getBool(_kToastErrorsKey) ?? true;
    toastShowWarningsNotifier.value = prefs.getBool(_kToastWarningsKey) ?? true;
    toastShowInfoNotifier.value = prefs.getBool(_kToastInfoKey) ?? true;
    showSenderNotifier.value = prefs.getBool(_kShowSenderKey) ?? true;
    showContentNotifier.value = prefs.getBool(_kShowContentKey) ?? true;
    showMediaPreviewNotifier.value =
        prefs.getBool(_kShowMediaPreviewKey) ?? true;
    final rawMuted = prefs.getString(_kMutedPeersKey);
    if (rawMuted != null) {
      try {
        mutedPeersNotifier.value = (jsonDecode(rawMuted) as List)
            .cast<String>()
            .toSet();
      } catch (_) {}
    }
  }

  bool isMuted(String peer) => mutedPeersNotifier.value.contains(peer);

  Future<void> setEnabled(bool v) async {
    enabledNotifier.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, v);
  }

  Future<void> setMuted(String peer, bool muted) async {
    final next = Set<String>.of(mutedPeersNotifier.value);
    if (muted) {
      next.add(peer);
    } else {
      next.remove(peer);
    }
    mutedPeersNotifier.value = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMutedPeersKey, jsonEncode(next.toList()));
  }

  Future<void> setToastEnabled(bool v) async {
    toastEnabledNotifier.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kToastEnabledKey, v);
  }

  Future<void> setToastShowErrors(bool v) async {
    toastShowErrorsNotifier.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kToastErrorsKey, v);
  }

  Future<void> setToastShowWarnings(bool v) async {
    toastShowWarningsNotifier.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kToastWarningsKey, v);
  }

  Future<void> setToastShowInfo(bool v) async {
    toastShowInfoNotifier.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kToastInfoKey, v);
  }

  Future<void> setShowSender(bool v) async {
    showSenderNotifier.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShowSenderKey, v);
  }

  Future<void> setShowContent(bool v) async {
    showContentNotifier.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShowContentKey, v);
  }

  Future<void> setShowMediaPreview(bool v) async {
    showMediaPreviewNotifier.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kShowMediaPreviewKey, v);
  }
}
