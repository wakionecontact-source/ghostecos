// Разрешения приложения.
//
// Онбординг: requestAllPermissions() — пачкой, ТОЛЬКО по кнопке «Запросить».
// Рантайм (если на онбординге нажали «Пропустить»): ensurePermission(p) —
// лениво, прямо перед действием (запись голосового, вложение фото и т.д.).
//
// Список под актуальный апп и манифест: уведомления, микрофон (голосовые),
// фото/видео (галерея), фон (батарея), Bluetooth/геолокация/поиск устройств
// (LAN/BLE/Wi-Fi Direct — экран «Устройства поблизости»).
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/toast_overlay.dart';
import '../core/local/app_logger.dart';

/// Разрешения, которые реально нужны приложению (совпадает с AndroidManifest).
const List<Permission> appPermissions = <Permission>[
  Permission.notification,
  Permission.microphone,
  Permission.photos,
  Permission.videos,
  // Специальный Android-доступ «Все файлы» (Android 11+). Это не обычный
  // runtime-dialog: permission_handler откроет системный экран доступа.
  Permission.manageExternalStorage,
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
  if (p == Permission.manageExternalStorage) return 'Все файлы';
  if (p == Permission.ignoreBatteryOptimizations) return 'Работа в фоне';
  // Три РАЗНЫХ Android-разрешения — если подписать одинаково («Bluetooth»
  // x3), список выглядит как баг-дубль (перенос лейблов из 1.19.3).
  if (p == Permission.bluetoothScan) return 'Bluetooth (поиск)';
  if (p == Permission.bluetoothConnect) return 'Bluetooth (подключение)';
  if (p == Permission.bluetoothAdvertise) return 'Bluetooth (видимость)';
  if (p == Permission.nearbyWifiDevices) return 'Устройства поблизости';
  if (p == Permission.locationWhenInUse) return 'Геолокация';
  return p.toString();
}

String permDesc(Permission p) {
  if (p == Permission.notification) return 'Оповещения о новых сообщениях';
  if (p == Permission.microphone) return 'Запись голосовых сообщений';
  if (p == Permission.photos) return 'Отправка фото из галереи';
  if (p == Permission.videos) return 'Отправка видео из галереи';
  if (p == Permission.manageExternalStorage) {
    return 'Доступ к файлам устройства через файловый проводник';
  }
  if (p == Permission.ignoreBatteryOptimizations) {
    return 'Доставка сообщений при свёрнутом приложении';
  }
  if (p == Permission.bluetoothScan ||
      p == Permission.bluetoothConnect ||
      p == Permission.bluetoothAdvertise) {
    return 'Поиск устройств рядом по BLE';
  }
  if (p == Permission.nearbyWifiDevices)
    return 'Поиск устройств по Wi-Fi Direct';
  if (p == Permission.locationWhenInUse) {
    return 'Нужна системе для поиска по Bluetooth/Wi-Fi Direct';
  }
  return '';
}

IconData permIcon(Permission p) {
  if (p == Permission.notification) return CupertinoIcons.bell;
  if (p == Permission.microphone) return CupertinoIcons.mic;
  if (p == Permission.photos) return CupertinoIcons.photo;
  if (p == Permission.videos) return CupertinoIcons.videocam;
  if (p == Permission.manageExternalStorage) return CupertinoIcons.folder;
  if (p == Permission.ignoreBatteryOptimizations) return Icons.battery_saver;
  if (p == Permission.bluetoothScan ||
      p == Permission.bluetoothConnect ||
      p == Permission.bluetoothAdvertise)
    return CupertinoIcons.bluetooth;
  if (p == Permission.nearbyWifiDevices)
    return CupertinoIcons.antenna_radiowaves_left_right;
  if (p == Permission.locationWhenInUse) return CupertinoIcons.location;
  return CupertinoIcons.shield;
}

/// Локальный аудит реального использования разрешений.
///
/// Здесь нет путей к файлам, текста сообщений или других пользовательских
/// данных: сохраняются только разрешение, контролируемый контекст действия,
/// время и результат. Это переживает перезапуск приложения и дублируется в
/// оперативный журнал приложения.
class PermissionUsage {
  final DateTime at;
  final String context;
  final String result;

  const PermissionUsage({
    required this.at,
    required this.context,
    required this.result,
  });

  factory PermissionUsage.fromJson(Map<String, dynamic> json) {
    final parsed = DateTime.tryParse('${json['at'] ?? ''}');
    return PermissionUsage(
      at: parsed ?? DateTime.fromMillisecondsSinceEpoch(0),
      context: '${json['context'] ?? 'other'}',
      result: '${json['result'] ?? 'unknown'}',
    );
  }

  Map<String, dynamic> toJson() => {
    'at': at.toIso8601String(),
    'context': context,
    'result': result,
  };
}

class PermissionUsageAudit extends ChangeNotifier {
  PermissionUsageAudit._();
  static final PermissionUsageAudit instance = PermissionUsageAudit._();

  static const _prefsKey = 'gs_permission_usage_v1';
  Map<String, PermissionUsage> _last = {};
  Future<void>? _loadFuture;

  static const contextLabels = <String, String>{
    'onboarding': 'Онбординг',
    'voice_message': 'Голосовое сообщение',
    'lan_scan': 'Поиск устройств поблизости',
    'attachment_gallery': 'Галерея (скрепка)',
    'attachment_file': 'Файловый проводник',
    'notification_message': 'Уведомление о сообщении',
    'foreground_service': 'Фоновая связь',
    'other': 'Другое действие',
  };

  Future<void> load() {
    final running = _loadFuture;
    if (running != null) return running;
    final future = _loadInternal();
    _loadFuture = future;
    return future.whenComplete(() {
      if (identical(_loadFuture, future)) _loadFuture = null;
    });
  }

  Future<void> _loadInternal() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      _last = decoded.map((key, value) {
        final data = value is Map
            ? Map<String, dynamic>.from(value)
            : <String, dynamic>{};
        return MapEntry('$key', PermissionUsage.fromJson(data));
      });
    } catch (e) {
      appLog.warn('permissions', 'usage audit load failed: $e');
    }
  }

  PermissionUsage? lastFor(Permission permission) =>
      _last[permissionKey(permission)];

  Future<void> recordCurrentStatus(
    Permission permission, {
    required String context,
  }) async {
    await _auditPermissionStatus(
      permission,
      context: context,
      status: await permission.status,
    );
  }

  Future<void> recordStatus(
    Permission permission, {
    required String context,
    required String result,
  }) async {
    await load();
    final safeContext = contextLabels.containsKey(context) ? context : 'other';
    final safeResult =
        const {'granted', 'limited', 'denied', 'error'}.contains(result)
        ? result
        : 'error';
    final entry = PermissionUsage(
      at: DateTime.now(),
      context: safeContext,
      result: safeResult,
    );
    _last[permissionKey(permission)] = entry;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(_last.map((key, value) => MapEntry(key, value.toJson()))),
      );
    } catch (e) {
      appLog.warn('permissions', 'usage audit save failed: $e');
    }
    appLog.info(
      'permissions',
      'permission=${permissionKey(permission)} context=$safeContext result=$safeResult',
    );
    notifyListeners();
  }
}

String permissionKey(Permission p) => p.toString();

String permissionUsageLabel(PermissionUsage? usage) {
  if (usage == null) return 'Ещё не использовалось';
  final local = usage.at.toLocal();
  final day = local.day.toString().padLeft(2, '0');
  final month = local.month.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  final place =
      PermissionUsageAudit.contextLabels[usage.context] ?? 'Другое действие';
  return '$day.$month.${local.year} $hour:$minute · $place';
}

Future<void> _auditPermissionStatus(
  Permission p, {
  required String context,
  required PermissionStatus status,
}) {
  final result = status.isGranted
      ? 'granted'
      : status.isLimited
      ? 'limited'
      : 'denied';
  return PermissionUsageAudit.instance.recordStatus(
    p,
    context: context,
    result: result,
  );
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
  if (wanted.contains(Permission.manageExternalStorage) &&
      await Permission.manageExternalStorage.isDenied) {
    // Android открывает отдельный системный экран для MANAGE_EXTERNAL_STORAGE.
    await Permission.manageExternalStorage.request();
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
  final statuses = await checkAllPermissions();
  for (final p in wanted) {
    final status = statuses[p];
    if (status != null) {
      await _auditPermissionStatus(p, context: 'onboarding', status: status);
    }
  }
  return statuses;
}

/// Лениво: гарантировать ОДНО разрешение перед действием. true = выдано.
/// Вызывать прямо перед операцией (запись/вложение), если юзер «Пропустил»
/// онбординг-запрос. Если отклонено навсегда — открываем системные настройки.
Future<bool> ensurePermission(Permission p, {String context = 'other'}) async {
  final status = await p.status;
  if (status.isGranted || status.isLimited) {
    await _auditPermissionStatus(p, context: context, status: status);
    return true;
  }
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
    await _auditPermissionStatus(p, context: context, status: after);
    return after.isGranted || after.isLimited;
  }
  final res = await p.request();
  await _auditPermissionStatus(p, context: context, status: res);
  return res.isGranted || res.isLimited;
}
