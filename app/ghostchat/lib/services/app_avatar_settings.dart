import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Runtime choice for the app avatar shown by GhostChat's own surfaces.
///
/// Android's small notification icon is intentionally kept as a separate
/// monochrome resource because Android tints that icon at notification time.
class AppAvatarSettings {
  AppAvatarSettings._();

  static final AppAvatarSettings instance = AppAvatarSettings._();

  static const variantCount = 20;
  static const defaultVariant = 0;
  static const _selectedVariantKey = 'app_avatar_variant_v1';
  static const variantNames = <String>[
    'Оригинальная аватарка',
    'Чёрный / белый',
    'Белый / чёрный',
    'Ночной синий / ледяной',
    'Сланцевый / небесный',
    'Тёмный бирюзовый / мятный',
    'Пыльный бирюзовый / кремовый',
    'Лесной / шалфейный',
    'Оливковый / бежевый',
    'Тёмная слива / лавандовый',
    'Пыльный лиловый / розовый',
    'Бордо / пудровый',
    'Кирпичный / персиковый',
    'Эспрессо / персиковый',
    'Ореховый / песочный',
    'Тёмный янтарь / ванильный',
    'Терракотовый / кремовый',
    'Глубокий циан / аквамариновый',
    'Индиго / перивинкл',
    'Сине-серый / стальной',
  ];
  static const _platformChannel = MethodChannel('ghostchat/app');

  bool _loaded = false;
  final ValueNotifier<int> selectedVariantNotifier = ValueNotifier(
    defaultVariant,
  );

  int get selectedVariant => selectedVariantNotifier.value;

  String assetPathFor(int variant) {
    final safeVariant = variant.clamp(0, variantCount - 1).toInt();
    return 'assets/app_avatars/app_avatar_${(safeVariant + 1).toString().padLeft(2, '0')}.png';
  }

  String variantNameFor(int variant) {
    final safeVariant = variant.clamp(0, variantCount - 1).toInt();
    return variantNames[safeVariant];
  }

  String get selectedAssetPath => assetPathFor(selectedVariant);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(_selectedVariantKey);
      if (saved != null && saved >= 0 && saved < variantCount) {
        selectedVariantNotifier.value = saved;
      }
    } catch (_) {
      // The first black/white variant remains a safe in-session default.
    }
  }

  Future<void> setSelectedVariant(int variant) async {
    if (variant < 0 || variant >= variantCount) return;
    selectedVariantNotifier.value = variant;
    await persistSelectedVariant();
  }

  Future<void> persistSelectedVariant() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_selectedVariantKey, selectedVariant);
    } catch (_) {
      // Keep the live selection if persistence is temporarily unavailable.
    }
  }

  Future<bool> restartApp() async {
    await persistSelectedVariant();
    try {
      await _platformChannel.invokeMethod<void>('restartApp', <String, dynamic>{
        'variant': selectedVariant,
      });
      return true;
    } catch (_) {
      return false;
    }
  }
}
