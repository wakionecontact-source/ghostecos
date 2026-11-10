/// Совместимый слой для старых экранов: все цвета берутся из единой
/// палитры [AppPalette]. Новый код должен использовать `GE`/`AppPalette`.
library;

import 'package:flutter/material.dart';
import '../../design/app_palette.dart';

class AppColors {
  AppColors._();
  static const bg = AppPalette.bg;
  static const bgDeep = AppPalette.bgDeep;
  static const surface = AppPalette.surface;
  static const surfaceElevated = AppPalette.surfaceElevated;
  static const primary = AppPalette.accent;
  static const primary2 = AppPalette.accentDeep;
  static const text = AppPalette.text;
  static const sub = AppPalette.textSecondary;
  static const faint = AppPalette.textMuted;
  static const red = AppPalette.danger;
  static const blue = AppPalette.info;
  static const green = AppPalette.success;
  static const border = AppPalette.border;

  static const primaryGradient = AppPalette.accentGradient;
}

class AppTheme {
  AppTheme._();

  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: AppColors.primary,
      secondary: AppColors.primary2,
      surface: AppColors.surface,
      error: AppColors.red,
      onPrimary: AppPalette.onAccent,
      onSurface: AppColors.text,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.bg,
      colorScheme: scheme,
      fontFamily: 'Inter',
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        foregroundColor: AppColors.text,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        hintStyle: const TextStyle(color: AppColors.faint),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        errorStyle: const TextStyle(color: AppColors.red),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppPalette.onAccent,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AppColors.surfaceElevated,
        contentTextStyle: TextStyle(color: AppColors.text),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
