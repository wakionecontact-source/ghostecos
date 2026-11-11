/// Токены GhostUI.
///
/// Единственный источник цветов, радиусов и отступов. Экраны не задают
/// собственные радиусы: любая ступень выводится из одного мастер-значения
/// [UiTokens.radius].
library;

import 'package:flutter/material.dart';

import '../design/app_palette.dart';

/// Коэффициенты ступеней радиуса. Значение `pill` — не ступень, а признак
/// «полностью скруглено» (999).
const Map<String, double> uiRadiusSteps = <String, double>{
  'xs': 0.35,
  's': 0.7,
  'm': 1.0,
  'l': 1.4,
  'xl': 1.8,
};

class UiTokens {
  const UiTokens({
    required this.colors,
    required this.radius,
    required this.spacing,
  });

  final Map<String, Color> colors;
  final double radius;
  final Map<String, double> spacing;

  /// Запасная палитра, если конфиг не загрузился. Совпадает с текущим
  /// дизайном, поэтому приложение стартует в любом случае.
  factory UiTokens.bootstrap() => const UiTokens(
    colors: <String, Color>{
      'bg': AppPalette.bg,
      'bgDeep': AppPalette.bgDeep,
      'surface': AppPalette.surface,
      'surfaceElevated': AppPalette.surfaceElevated,
      'surfacePressed': AppPalette.surfacePressed,
      'text': AppPalette.text,
      'textSecondary': AppPalette.textSecondary,
      'textMuted': AppPalette.textMuted,
      'accent': AppPalette.accent,
      'accentDeep': AppPalette.accentDeep,
      'accentSoft': AppPalette.accentSoft,
      'onAccent': AppPalette.onAccent,
      'success': AppPalette.success,
      'warning': AppPalette.warning,
      'danger': AppPalette.danger,
      'info': AppPalette.info,
      'transparent': AppPalette.transparent,
    },
    radius: 14,
    spacing: <String, double>{
      'xs': 4,
      's': 8,
      'm': 12,
      'l': 16,
      'xl': 24,
      'xxl': 32,
    },
  );

  Color color(String name, {Color fallback = const Color(0x00000000)}) {
    return colors[name] ?? fallback;
  }

  double radiusStep(String step) {
    if (step == 'pill') return 999;
    final factor = uiRadiusSteps[step];
    if (factor == null) return radius;
    return radius * factor;
  }
}
