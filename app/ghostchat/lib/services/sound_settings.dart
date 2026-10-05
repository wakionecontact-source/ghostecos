import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ghost_sound_waveforms.dart';

/// User-controlled sound effects for GhostChat's interface and notifications.
class SoundSettings {
  SoundSettings._();

  static final SoundSettings instance = SoundSettings._();
  static const int tapVariantCount = GhostSoundWaveforms.tapVariantCount;
  static const int effectVariantCount = GhostSoundWaveforms.effectVariantCount;
  static const int defaultTapVariant = 6;

  static const _uiEnabledKey = 'ghost_sound_ui_enabled_v1';
  static const _notificationsEnabledKey =
      'ghost_sound_notifications_enabled_v1';
  static const _uiTapVariantKey = 'ghost_sound_ui_tap_variant_v1';
  static const _notificationVariantKey = 'ghost_sound_notification_variant_v1';
  static const _callVariantKey = 'ghost_sound_call_variant_v1';
  static const _successVariantKey = 'ghost_sound_success_variant_v1';
  static const _warningVariantKey = 'ghost_sound_warning_variant_v1';
  static const _errorVariantKey = 'ghost_sound_error_variant_v1';

  final ValueNotifier<bool> uiSoundsEnabledNotifier = ValueNotifier(false);
  final ValueNotifier<int> uiTapVariantNotifier = ValueNotifier(
    defaultTapVariant,
  );
  final ValueNotifier<int> notificationVariantNotifier = ValueNotifier(0);
  final ValueNotifier<int> callVariantNotifier = ValueNotifier(0);
  final ValueNotifier<int> successVariantNotifier = ValueNotifier(0);
  final ValueNotifier<int> warningVariantNotifier = ValueNotifier(0);
  final ValueNotifier<int> errorVariantNotifier = ValueNotifier(0);
  final ValueNotifier<bool> notificationSoundsEnabledNotifier = ValueNotifier(
    false,
  );
  bool _loaded = false;
  Future<void>? _loading;

  Future<void> load() => _loaded ? Future.value() : (_loading ??= _load());

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      uiSoundsEnabledNotifier.value = prefs.getBool(_uiEnabledKey) ?? false;
      uiTapVariantNotifier.value =
          (prefs.getInt(_uiTapVariantKey) ?? defaultTapVariant)
              .clamp(0, GhostSoundWaveforms.tapVariantCount - 1)
              .toInt();
      notificationVariantNotifier.value = _readVariant(
        prefs,
        _notificationVariantKey,
      );
      callVariantNotifier.value = _readVariant(prefs, _callVariantKey);
      successVariantNotifier.value = _readVariant(prefs, _successVariantKey);
      warningVariantNotifier.value = _readVariant(prefs, _warningVariantKey);
      errorVariantNotifier.value = _readVariant(prefs, _errorVariantKey);
      notificationSoundsEnabledNotifier.value =
          prefs.getBool(_notificationsEnabledKey) ?? false;
      _loaded = true;
    } finally {
      _loading = null;
    }
  }

  Future<void> setUiSoundsEnabled(bool enabled) async {
    uiSoundsEnabledNotifier.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_uiEnabledKey, enabled);
  }

  Future<void> setUiTapVariant(int variant) async {
    final normalized = variant
        .clamp(0, GhostSoundWaveforms.tapVariantCount - 1)
        .toInt();
    uiTapVariantNotifier.value = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_uiTapVariantKey, normalized);
  }

  int _readVariant(SharedPreferences prefs, String key) =>
      (prefs.getInt(key) ?? 0).clamp(0, effectVariantCount - 1).toInt();

  Future<void> setNotificationVariant(int variant) => _setVariant(
    _notificationVariantKey,
    notificationVariantNotifier,
    variant,
  );

  Future<void> setCallVariant(int variant) =>
      _setVariant(_callVariantKey, callVariantNotifier, variant);

  Future<void> setSuccessVariant(int variant) =>
      _setVariant(_successVariantKey, successVariantNotifier, variant);

  Future<void> setWarningVariant(int variant) =>
      _setVariant(_warningVariantKey, warningVariantNotifier, variant);

  Future<void> setErrorVariant(int variant) =>
      _setVariant(_errorVariantKey, errorVariantNotifier, variant);

  Future<void> _setVariant(
    String key,
    ValueNotifier<int> notifier,
    int variant,
  ) async {
    final normalized = variant.clamp(0, effectVariantCount - 1).toInt();
    notifier.value = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, normalized);
  }

  Future<void> setNotificationSoundsEnabled(bool enabled) async {
    notificationSoundsEnabledNotifier.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_notificationsEnabledKey, enabled);
  }
}
