// Разрешения приложения.
//
// Онбординг: requestAllPermissions() — пачкой, ТОЛЬКО по кнопке «Запросить».
// Рантайм (если на онбординге нажали «Пропустить»): ensurePermission(p) —
// лениво, прямо перед действием (запись голосового, вложение фото и т.д.).
//
// Список под актуальный апп и манифест: уведомления, микрофон (голосовые),
// фото/видео (галерея), фон (батарея), Bluetooth/геолокация/поиск устройств
// (LAN/BLE/Wi-Fi Direct — экран «Устройства поблизости»).
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../widgets/toast_overlay.dart';

/// Разрешения, которые реально нужны приложению (совпадает с AndroidManifest).
const List<Permission> appPermissions = <Permission>[
  Permission.notification,
  Permission.microphone,
  Permission.photos,
  Permission.videos,
  Permission.ignoreBatteryOptimizations,
  Permission.bluetoothScan,
  Permission.bluetoothConnect,
  Permission.bluetoothAdvertise,
  Permission.nearbyWifiDevices,
  Permission.locationWhenInUse,
];

String permLabel(Permission p) {
  if (p == Permission.notification) return 'Уведомления';
  if (p == Permission.microphone) return 'Микрофон';
  if (p == Permission.photos) return 'Фото';
  if (p == Permission.videos) return 'Видео';
  if (p == Permission.ignoreBatteryOptimizations) return 'Работа в фоне';
  if (p == Permission.bluetoothScan ||
      p == Permission.bluetoothConnect ||
      p == Permission.bluetoothAdvertise) return 'Bluetooth';
  if (p == Permission.nearbyWifiDevices) return 'Устройства поблизости';
  if (p == Permission.locationWhenInUse) return 'Геолокация';
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
  if (p == Permission.bluetoothScan ||
      p == Permission.bluetoothConnect ||
      p == Permission.bluetoothAdvertise) {
    return 'Поиск устройств рядом по BLE';
  }
  if (p == Permission.nearbyWifiDevices) return 'Поиск устройств по Wi-Fi Direct';
  if (p == Permission.locationWhenInUse) {
    return 'Нужна системе для поиска по Bluetooth/Wi-Fi Direct';
  }
  return '';
}

IconData permIcon(Permission p) {
  if (p == Permission.notification) return Icons.notifications_outlined;
  if (p == Permission.microphone) return Icons.mic_outlined;
  if (p == Permission.photos) return Icons.photo_outlined;
  if (p == Permission.videos) return Icons.videocam_outlined;
  if (p == Permission.ignoreBatteryOptimizations) return Icons.battery_saver;
  if (p == Permission.bluetoothScan ||
      p == Permission.bluetoothConnect ||
      p == Permission.bluetoothAdvertise) return Icons.bluetooth;
  if (p == Permission.nearbyWifiDevices) return Icons.wifi_tethering;
  if (p == Permission.locationWhenInUse) return Icons.location_on_outlined;
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
/// [only] — если передан, запрашиваются только эти разрешения (галочки
/// юзера в списке на онбординге); по умолчанию — все [appPermissions].
Future<Map<Permission, PermissionStatus>> requestAllPermissions({
  Set<Permission>? only,
}) async {
  final wanted = only ?? appPermissions.toSet();
  if (wanted.contains(Permission.ignoreBatteryOptimizations) &&
      await Permission.ignoreBatteryOptimizations.isDenied) {
    await Permission.ignoreBatteryOptimizations.request();
  }
  final batch = <Permission>[
    Permission.notification,
    Permission.microphone,
    Permission.photos,
    Permission.videos,
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.bluetoothAdvertise,
    Permission.nearbyWifiDevices,
    Permission.locationWhenInUse,
  ].where(wanted.contains).toList();
  if (batch.isNotEmpty) await batch.request();
  return checkAllPermissions();
}

/// Лениво: гарантировать ОДНО разрешение перед действием. true = выдано.
/// Вызывать прямо перед операцией (запись/вложение), если юзер «Пропустил»
/// онбординг-запрос. Если отклонено навсегда — открываем системные настройки.
Future<bool> ensurePermission(Permission p) async {
  final status = await p.status;
  if (status.isGranted || status.isLimited) return true;
  if (status.isPermanentlyDenied) {
    // Android больше не даёт повторно показать системный диалог для
    // разрешения, отклонённого "не спрашивать снова" — переход в настройки
    // тут единственный путь. Без этого тоста редирект выглядит как баг
    // ("почему сразу настройки, а не запрос?"), хотя это ожидаемое поведение
    // ОС именно для ЭТОГО разрешения (остальные в списке ещё не отклонены
    // навсегда и покажут обычный диалог).
    toast.show('«${permLabel(p)}» отклонено ранее — включите в настройках');
    await openAppSettings();
    final after = await p.status;
    return after.isGranted || after.isLimited;
  }
  final res = await p.request();
  return res.isGranted || res.isLimited;
}
