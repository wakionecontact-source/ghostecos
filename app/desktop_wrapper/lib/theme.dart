// Палитра и тема экосистемы Ghost. Поля цвета — static (НЕ const), чтобы
// ThemeService мог переключать палитру на лету.
import 'package:flutter/material.dart';

class GE {
  // ── Бэкенд ─────────────────────────────────────────────────────────────
  static const baseUrl = 'https://ghostecos.duckdns.org';
  static const apiChat = '$baseUrl/api/chat';
  static const apiSoc = '$baseUrl/api/soc';
  static const wsUrl = 'wss://ghostecos.duckdns.org/api/soc/ws';
  static const appName = 'Ghost';

  // ── Цвета (по умолчанию — Полночь, перезаписываются ThemeService) ──────
  static Color bg = const Color(0xFF020617);
  static Color bgDeep = const Color(0xFF060A1A);
  static Color surface = const Color(0xCC0F172A);
  static Color border = const Color(0x14FFFFFF);
  static Color borderStrong = const Color(0x21FFFFFF);
  static Color primary = const Color(0xFFA855F7);
  static Color primary2 = const Color(0xFF7C3AED);
  static Color text = const Color(0xFFF1F5F9);
  static Color sub = const Color(0xFF94A3B8);
  static Color muted = const Color(0xFF64748B);
  static Color green = const Color(0xFF4ADE80);
  static Color yellow = const Color(0xFFFBBF24);
  static Color red = const Color(0xFFF87171);
  static Color blue = const Color(0xFF22D3EE);

  // ── Glass-параметры ─────────────────────────────────────────────────────
  static Color glassFill = const Color(0x4D0F172A);
  static Color glassBorder = const Color(0x33FFFFFF);
  static Color glowFill = const Color(0x33A855F7);
  static Brightness currentBrightness = Brightness.dark;

  /// Размытие фона за карточкой (sigma для BackdropFilter).
  static const glassBlur = 18.0;
  /// Толщина бордера стекла.
  static const glassStroke = 1.0;
  /// Скругление по умолчанию.
  static const radiusSm = 10.0;
  static const radiusMd = 16.0;
  static const radiusLg = 22.0;

  static ThemeData theme() => ThemeData(
        useMaterial3: true,
        brightness: currentBrightness,
        scaffoldBackgroundColor: Colors.transparent,
        fontFamily: 'Inter',
        colorScheme: ColorScheme.fromSeed(
          seedColor: primary,
          brightness: currentBrightness,
          surface: bg,
          surfaceContainerHighest: glassFill,
        ),
        textTheme: TextTheme(
          bodyMedium: TextStyle(color: text, fontSize: 14, height: 1.45),
          bodySmall: TextStyle(color: sub, fontSize: 12, height: 1.4),
          titleLarge: TextStyle(color: text, fontSize: 22, fontWeight: FontWeight.w700),
          titleMedium: TextStyle(color: text, fontSize: 16, fontWeight: FontWeight.w600),
          labelLarge: TextStyle(color: text, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: text, fontSize: 17, fontWeight: FontWeight.w700,
          ),
          iconTheme: IconThemeData(color: text),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: bg,
          contentTextStyle: TextStyle(color: text),
        ),
      );
}
