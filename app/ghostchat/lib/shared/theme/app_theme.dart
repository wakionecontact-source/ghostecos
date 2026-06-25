/// Тема GhostChat — тёмная, фиолетовый акцент (цвета из лендинга ghostecos).
library;

import 'package:flutter/material.dart';

class AppColors {
  AppColors._();
  static const bg = Color(0xFF020617);
  static const bgDeep = Color(0xFF060A1A);
  static const surface = Color(0xFF0F172A);
  static const primary = Color(0xFFA855F7);
  static const primary2 = Color(0xFF7C3AED);
  static const text = Color(0xFFF1F5F9);
  static const sub = Color(0xFF94A3B8);
  static const faint = Color(0xFF475569);
  static const red = Color(0xFFF43F5E);
  static const blue = Color(0xFF3B82F6);
  static const green = Color(0xFF22C55E);
  static const border = Color(0x1FFFFFFF);

  static const primaryGradient = LinearGradient(
    colors: [primary, primary2],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
}

class AppTheme {
  AppTheme._();

  static ThemeData get dark {
    const scheme = ColorScheme.dark(
      primary: AppColors.primary,
      secondary: AppColors.primary2,
      surface: AppColors.surface,
      error: AppColors.red,
      onPrimary: Colors.white,
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
        fillColor: AppColors.surface.withValues(alpha: 0.6),
        hintStyle: const TextStyle(color: AppColors.faint),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary),
        ),
        errorStyle: const TextStyle(color: AppColors.red),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AppColors.surface,
        contentTextStyle: TextStyle(color: AppColors.text),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
