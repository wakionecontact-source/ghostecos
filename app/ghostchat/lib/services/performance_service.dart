import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AnimationQuality { best, standard, none }

enum GuiQuality { best, low }

/// Runtime rendering policy for normal appearance and the optional
/// energy-saving profile.
///
/// The values selected in the energy-saving screen are overrides, not global
/// visual preferences: while the profile is inactive the app keeps its normal
/// appearance and the full-rate mesh. This is important because a setting
/// called "quality for energy saving" must not degrade the app at 80% battery.
class PerformanceService with WidgetsBindingObserver {
  PerformanceService._();

  static final PerformanceService instance = PerformanceService._();

  static const MethodChannel _channel = MethodChannel('ghostchat/performance');
  static const Duration _pollInterval = Duration(seconds: 20);
  static const List<int> backgroundFpsOptions = [60, 30, 15];
  static const int minBatteryThreshold = 5;
  static const int maxBatteryThreshold = 50;
  // Небольшая пауза перед применением нового профиля даёт текущим
  // переходам закончиться. Иначе TickerMode/disableAnimations обрывали
  // анимацию прямо посреди жеста или переключения экрана.
  static const Duration _profileApplyDelay = Duration(milliseconds: 450);

  static const _backgroundFpsKey = 'performance_background_fps_v1';
  static const _animationQualityKey = 'performance_animation_quality_v1';
  static const _guiQualityKey = 'performance_gui_quality_v1';
  static const _appearanceBackgroundFpsKey =
      'performance_appearance_background_fps_v1';
  static const _appearanceAnimationQualityKey =
      'performance_appearance_animation_quality_v1';
  static const _appearanceGuiQualityKey =
      'performance_appearance_gui_quality_v1';
  static const _automaticEnergySavingKey = 'performance_auto_energy_saving_v1';
  static const _batteryThresholdKey = 'performance_battery_threshold_v1';
  static const _systemPowerSaveKey = 'performance_system_power_save_v1';
  static const _thermalProtectionKey = 'performance_thermal_protection_v1';
  static const _energyMeshKey = 'performance_energy_mesh_enabled_v1';
  static const _energyMeshSpeedKey = 'performance_energy_mesh_speed_v1';

  final ValueNotifier<bool> reducedEffectsNotifier = ValueNotifier(false);
  final ValueNotifier<int?> batteryLevelNotifier = ValueNotifier(null);
  final ValueNotifier<bool> energySavingActiveNotifier = ValueNotifier(false);
  final ValueNotifier<bool> manualEnergySavingNotifier = ValueNotifier(false);
  final ValueNotifier<bool> automaticEnergySavingNotifier = ValueNotifier(true);
  final ValueNotifier<int> batteryThresholdNotifier = ValueNotifier(5);
  final ValueNotifier<bool> systemPowerSaveNotifier = ValueNotifier(true);
  final ValueNotifier<bool> thermalProtectionNotifier = ValueNotifier(true);

  // These are the user's selected values for the energy-saving profile.
  final ValueNotifier<int> backgroundFpsNotifier = ValueNotifier(15);
  final ValueNotifier<AnimationQuality> animationQualityNotifier =
      ValueNotifier(AnimationQuality.standard);
  final ValueNotifier<GuiQuality> guiQualityNotifier = ValueNotifier(
    GuiQuality.low,
  );
  final ValueNotifier<bool> energyMeshEnabledNotifier = ValueNotifier(true);
  final ValueNotifier<double> energyMeshSpeedNotifier = ValueNotifier(0.25);

  // Постоянные настройки обычного режима (Внешний вид). Профиль
  // энергосбережения временно подменяет их своими значениями, пока активен.
  final ValueNotifier<int> appearanceBackgroundFpsNotifier = ValueNotifier(60);
  final ValueNotifier<AnimationQuality> appearanceAnimationQualityNotifier =
      ValueNotifier(AnimationQuality.best);
  final ValueNotifier<GuiQuality> appearanceGuiQualityNotifier = ValueNotifier(
    GuiQuality.best,
  );
  Timer? _pollTimer;
  Timer? _profileApplyTimer;
  Timer? _animationQualityTimer;
  bool _initialized = false;
  bool _powerSave = false;
  int _thermalStatus = 0;
  bool _manualDisableEnergySaving = false;

  bool get energySavingActive => energySavingActiveNotifier.value;
  bool get manualEnergySaving => manualEnergySavingNotifier.value;
  bool get manualEnergySavingDisabled => _manualDisableEnergySaving;
  bool get reducedEffects => guiQuality == GuiQuality.low;
  bool get animationsDisabled => animationQuality == AnimationQuality.none;
  AnimationQuality get animationQuality => energySavingActive
      ? animationQualityNotifier.value
      : appearanceAnimationQualityNotifier.value;
  GuiQuality get guiQuality => energySavingActive
      ? guiQualityNotifier.value
      : appearanceGuiQualityNotifier.value;
  int get backgroundFps => energySavingActive
      ? backgroundFpsNotifier.value
      : appearanceBackgroundFpsNotifier.value;

  bool get energyMeshEnabled => energyMeshEnabledNotifier.value;
  double get energyMeshSpeed => energyMeshSpeedNotifier.value;

  Duration animationDuration(Duration best) {
    switch (animationQuality) {
      case AnimationQuality.best:
        return best;
      case AnimationQuality.standard:
        return Duration(
          milliseconds: (best.inMilliseconds * 0.6).round().clamp(1, 180),
        );
      case AnimationQuality.none:
        return Duration.zero;
    }
  }

  /// Для AnimationController нужна ненулевая длительность даже в режиме
  /// «Без анимаций»; один миллисекундный шаг визуально остаётся мгновенным.
  Duration animationControllerDuration(Duration best) {
    final value = animationDuration(best);
    return value == Duration.zero ? const Duration(milliseconds: 1) : value;
  }

  /// Kept pure so the policy can be tested without an Android device.
  static bool shouldEnableEnergySaving({
    required bool automaticEnabled,
    required int? batteryLevel,
    required int batteryThreshold,
    required bool useSystemPowerSave,
    required bool powerSave,
    required bool useThermalProtection,
    required int thermalStatus,
  }) {
    if (!automaticEnabled) return false;
    final lowBattery =
        batteryLevel != null &&
        batteryLevel >= 0 &&
        batteryLevel <= batteryThreshold;
    // Android thermal status: 3 = serious, 4 = severe, 5 = emergency.
    return lowBattery ||
        (useSystemPowerSave && powerSave) ||
        (useThermalProtection && thermalStatus >= 3);
  }

  /// Backward-compatible helper for callers/tests that used the old policy.
  static bool shouldReduceEffects({
    required int? batteryLevel,
    required bool powerSave,
    required int thermalStatus,
  }) => shouldEnableEnergySaving(
    automaticEnabled: true,
    batteryLevel: batteryLevel,
    batteryThreshold: 5,
    useSystemPowerSave: true,
    powerSave: powerSave,
    useThermalProtection: true,
    thermalStatus: thermalStatus,
  );

  bool _shouldEnableEnergySaving() =>
      !_manualDisableEnergySaving &&
      (shouldEnableEnergySaving(
            automaticEnabled: automaticEnergySavingNotifier.value,
            batteryLevel: batteryLevelNotifier.value,
            batteryThreshold: batteryThresholdNotifier.value,
            useSystemPowerSave: systemPowerSaveNotifier.value,
            powerSave: _powerSave,
            useThermalProtection: thermalProtectionNotifier.value,
            thermalStatus: _thermalStatus,
          ) ||
          manualEnergySaving);

  void _updateEnergySaving() {
    final next = _shouldEnableEnergySaving();
    if (!next) {
      _profileApplyTimer?.cancel();
      _profileApplyTimer = null;
      if (energySavingActiveNotifier.value) {
        energySavingActiveNotifier.value = false;
      }
      _updateReducedEffects();
      return;
    }
    if (energySavingActiveNotifier.value || _profileApplyTimer != null) {
      _updateReducedEffects();
      return;
    }
    _profileApplyTimer = Timer(_profileApplyDelay, () {
      _profileApplyTimer = null;
      if (!_shouldEnableEnergySaving()) return;
      energySavingActiveNotifier.value = true;
      _updateReducedEffects();
    });
    _updateReducedEffects();
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    await _loadSettings();
    if (!Platform.isAndroid) return;
    await _refresh();
    _startPolling();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final fps = prefs.getInt(_backgroundFpsKey);
      if (fps != null && backgroundFpsOptions.contains(fps)) {
        backgroundFpsNotifier.value = fps;
      }
      final appearanceFps = prefs.getInt(_appearanceBackgroundFpsKey);
      if (appearanceFps != null &&
          backgroundFpsOptions.contains(appearanceFps)) {
        appearanceBackgroundFpsNotifier.value = appearanceFps;
      }
      final animation = prefs.getString(_animationQualityKey);
      if (animation != null) {
        animationQualityNotifier.value = _animationFromString(animation);
      }
      final appearanceAnimation = prefs.getString(
        _appearanceAnimationQualityKey,
      );
      if (appearanceAnimation != null) {
        appearanceAnimationQualityNotifier.value = _animationFromString(
          appearanceAnimation,
        );
      }
      final gui = prefs.getString(_guiQualityKey);
      if (gui != null) guiQualityNotifier.value = _guiFromString(gui);
      final appearanceGui = prefs.getString(_appearanceGuiQualityKey);
      if (appearanceGui != null) {
        appearanceGuiQualityNotifier.value = _guiFromString(appearanceGui);
      }

      automaticEnergySavingNotifier.value =
          prefs.getBool(_automaticEnergySavingKey) ?? true;
      final threshold = prefs.getInt(_batteryThresholdKey);
      if (threshold != null &&
          threshold >= minBatteryThreshold &&
          threshold <= maxBatteryThreshold) {
        batteryThresholdNotifier.value = threshold;
      }
      systemPowerSaveNotifier.value =
          prefs.getBool(_systemPowerSaveKey) ?? true;
      thermalProtectionNotifier.value =
          prefs.getBool(_thermalProtectionKey) ?? true;
      // Mesh remains visible by default in the energy profile, but at the
      // profile FPS. An explicit user choice to disable it is preserved.
      energyMeshEnabledNotifier.value = prefs.getBool(_energyMeshKey) ?? true;
      energyMeshSpeedNotifier.value =
          (prefs.getDouble(_energyMeshSpeedKey) ?? 0.25).clamp(0.25, 2.0);
      _updateEnergySaving();
    } catch (_) {
      // Настройки энергосбережения не должны блокировать запуск приложения.
    }
  }

  Future<void> _refresh() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('getState');
      if (raw is! Map) return;
      final level = (raw['level'] as num?)?.toInt();
      _powerSave = raw['powerSave'] == true;
      _thermalStatus = (raw['thermalStatus'] as num?)?.toInt() ?? 0;
      _updateBatteryLevel(level != null && level >= 0 ? level : null);
      _updateEnergySaving();
    } on PlatformException {
      // Desktop, old Android builds, or a temporarily unavailable channel:
      // keep the normal rendering policy.
    }
  }

  void _updateBatteryLevel(int? next) {
    final previous = batteryLevelNotifier.value;
    if (_manualDisableEnergySaving && next != null) {
      final reachedCritical = next <= minBatteryThreshold;
      final crossedAboveThreshold =
          previous != null &&
          previous <= batteryThresholdNotifier.value &&
          next > batteryThresholdNotifier.value;
      final crossedBackBelowThreshold =
          previous != null &&
          previous > batteryThresholdNotifier.value &&
          next <= batteryThresholdNotifier.value;
      // После ручного выключения не включаем профиль на каждом polling-цикле.
      // Снимаем блокировку только на критическом уровне или при полном цикле
      // через порог (вверх, а затем обратно вниз).
      if (reachedCritical ||
          crossedAboveThreshold ||
          crossedBackBelowThreshold) {
        _manualDisableEnergySaving = false;
      }
    }
    batteryLevelNotifier.value = next;
  }

  void _updateReducedEffects() {
    final next = reducedEffects;
    if (reducedEffectsNotifier.value != next) {
      reducedEffectsNotifier.value = next;
    }
  }

  static AnimationQuality _animationFromString(String? value) =>
      switch (value) {
        'standard' => AnimationQuality.standard,
        'none' => AnimationQuality.none,
        _ => AnimationQuality.best,
      };

  static GuiQuality _guiFromString(String? value) =>
      value == 'low' ? GuiQuality.low : GuiQuality.best;

  Future<void> setBackgroundFps(int value) async {
    if (!backgroundFpsOptions.contains(value)) return;
    backgroundFpsNotifier.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_backgroundFpsKey, value);
  }

  Future<void> setAnimationQuality(AnimationQuality value) async {
    _animationQualityTimer?.cancel();
    _animationQualityTimer = null;
    // Если профиль уже активен, не переводим корневой TickerMode в false
    // посреди текущего перехода. Выбор сохраняется сразу, а визуально
    // применяется после короткого grace-периода.
    if (energySavingActive && value == AnimationQuality.none) {
      _animationQualityTimer = Timer(_profileApplyDelay, () {
        _animationQualityTimer = null;
        animationQualityNotifier.value = value;
      });
    } else {
      animationQualityNotifier.value = value;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_animationQualityKey, value.name);
  }

  Future<void> setGuiQuality(GuiQuality value) async {
    guiQualityNotifier.value = value;
    _updateReducedEffects();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_guiQualityKey, value.name);
  }

  Future<void> setAppearanceBackgroundFps(int value) async {
    if (!backgroundFpsOptions.contains(value)) return;
    appearanceBackgroundFpsNotifier.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_appearanceBackgroundFpsKey, value);
  }

  Future<void> setAppearanceAnimationQuality(AnimationQuality value) async {
    appearanceAnimationQualityNotifier.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appearanceAnimationQualityKey, value.name);
  }

  Future<void> setAppearanceGuiQuality(GuiQuality value) async {
    appearanceGuiQualityNotifier.value = value;
    _updateReducedEffects();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appearanceGuiQualityKey, value.name);
  }

  Future<void> setAutomaticEnergySaving(bool value) async {
    automaticEnergySavingNotifier.value = value;
    _updateEnergySaving();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_automaticEnergySavingKey, value);
  }

  /// Включить профиль вручную, даже если заряд выше порога и системный
  /// режим Android выключен. При выключении это временный запрет авто-старта:
  /// он не снимается следующим polling-циклом, пока заряд не достигнет 5%
  /// или не пройдёт полный цикл через выбранный порог.
  Future<void> setManualEnergySaving(bool value) async {
    manualEnergySavingNotifier.value = value;
    _manualDisableEnergySaving = !value;
    _updateEnergySaving();
  }

  Future<void> setBatteryThreshold(int value) async {
    if (value < minBatteryThreshold || value > maxBatteryThreshold) return;
    batteryThresholdNotifier.value = value.round();
    _updateEnergySaving();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_batteryThresholdKey, value.round());
  }

  Future<void> setSystemPowerSave(bool value) async {
    systemPowerSaveNotifier.value = value;
    _updateEnergySaving();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_systemPowerSaveKey, value);
  }

  Future<void> setThermalProtection(bool value) async {
    thermalProtectionNotifier.value = value;
    _updateEnergySaving();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_thermalProtectionKey, value);
  }

  Future<void> setEnergyMeshEnabled(bool value) async {
    energyMeshEnabledNotifier.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_energyMeshKey, value);
  }

  Future<void> setEnergyMeshSpeed(double value) async {
    final next = value.clamp(0.25, 2.0).toDouble();
    energyMeshSpeedNotifier.value = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_energyMeshSpeedKey, next);
  }

  void _startPolling() {
    _pollTimer ??= Timer.periodic(_pollInterval, (_) => _refresh());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
      _startPolling();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _stopPolling();
    }
  }
}
