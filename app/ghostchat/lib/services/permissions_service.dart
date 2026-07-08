// Разрешения приложения.
//
// Онбординг: requestAllPermissions() — пачкой, ТОЛЬКО по кнопке «Запросить».
// Рантайм (если на онбординге нажали «Пропустить»): ensurePermission(p) —
// лениво, прямо перед действием (запись голосового, вложение фото и т.д.).
//
// Список под актуальный апп и манифест: уведомления, микрофон (голосовые),
// фото/видео (галерея), фон (батарея). НЕТ камеры/аудиофайлов/Bluetooth/Wi-Fi/
// гео — этих фич (съёмка, mesh) в новом GhostChat пока нет.
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Разрешения, которые реально нужны приложению (совпадает с AndroidManifest).
const List<Permission> appPermissions = <Permission>[
  Permission.notification,
  Permission.microphone,
  Permission.photos,
  Permission.videos,
  Permission.ignoreBatteryOptimizations,
];

String permLabel(Permission p) {
  if (p == Permission.notification) return 'Уведомления';
  if (p == Permission.microphone) return 'Микрофон';
  if (p == Permission.photos) return 'Фото';
  if (p == Permission.videos) return 'Видео';
  if (p == Permission.ignoreBatteryOptimizations) return 'Работа в фоне';
  return p.toString();
}

String permDesc(Permission p) {
  if (p == Permission.notification) return 'Оповещения о новых сообщениях';
  if (p == Permission.microphone) return 'Запись голосовых сообщений';
  if (p == Permission.photos) return 'Отправка фото из галереи';
  if (p == Permission.videos) return 'Отправка видео из галереи';
  if (p == Permission.ignoreBatteryOptimizations) {
    return 'Доставка сообщений при свёрнутом приложении';
  }
  return '';
}

IconData permIcon(Permission p) {
  if (p == Permission.notification) return Icons.notifications_outlined;
  if (p == Permission.microphone) return Icons.mic_outlined;
  if (p == Permission.photos) return Icons.photo_outlined;
  if (p == Permission.videos) return Icons.videocam_outlined;
  if (p == Permission.ignoreBatteryOptimizations) return Icons.battery_saver;
  return Icons.shield_outlined;
}

/// Статусы всех разрешений.
Future<Map<Permission, PermissionStatus>> checkAllPermissions() async {
  final result = <Permission, PermissionStatus>{};
  for (final p in appPermissions) {
    result[p] = await p.status;
  }
  return result;
}

/// Запросить все разом (кнопка «Запросить разрешения» на онбординге).
/// Батарея — отдельным системным диалогом, остальные пачкой.
Future<Map<Permission, PermissionStatus>> requestAllPermissions() async {
  if (await Permission.ignoreBatteryOptimizations.isDenied) {
    await Permission.ignoreBatteryOptimizations.request();
  }
  await <Permission>[
    Permission.notification,
    Permission.microphone,
    Permission.photos,
    Permission.videos,
  ].request();
  return checkAllPermissions();
}

/// Лениво: гарантировать ОДНО разрешение перед действием. true = выдано.
/// Вызывать прямо перед операцией (запись/вложение), если юзер «Пропустил»
/// онбординг-запрос. Если отклонено навсегда — открываем системные настройки.
Future<bool> ensurePermission(Permission p) async {
  final status = await p.status;
  if (status.isGranted || status.isLimited) return true;
  if (status.isPermanentlyDenied) {
    await openAppSettings();
    final after = await p.status;
    return after.isGranted || after.isLimited;
  }
  final res = await p.request();
  return res.isGranted || res.isLimited;
}
