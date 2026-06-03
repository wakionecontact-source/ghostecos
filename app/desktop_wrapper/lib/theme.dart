// Палитра и тема экосистемы Ghost. Тёмно-фиолетовая, как на сайте.
// Дизайн-язык — mesh-фон сквозной + жидкое стекло (glassmorphism) на карточках.
import 'package:flutter/material.dart';

class GE {
  // ── Бэкенд ─────────────────────────────────────────────────────────────
  static const baseUrl = 'https://ghostecos.duckdns.org';
  static const apiChat = '$baseUrl/api/chat';
  static const apiSoc = '$baseUrl/api/soc';
  static const wsUrl = 'wss://ghostecos.duckdns.org/api/soc/ws';
  static const appName = 'Ghost';

  // ── Цвета (по умолчанию — Тёмная, как в 1.19.3) ────────────────────────
  static const bg = Color(0xFF020617);          // глубокий фон
  static const bgDeep = Color(0xFF060A1A);
  static const surface = Color(0xCC0F172A);     // непрозрачная карточка (legacy)
  static const border = Color(0x14FFFFFF);
  static const borderStrong = Color(0x21FFFFFF);
  static const primary = Color(0xFFA855F7);     // фиолетовый акцент
  static const primary2 = Color(0xFF7C3AED);
  static const text = Color(0xFFF1F5F9);
  static const sub = Color(0xFF94A3B8);
  static const muted = Color(0xFF64748B);
  static const green = Color(0xFF4ADE80);
  static const yellow = Color(0xFFFBBF24);
  static const red = Color(0xFFF87171);
  static const blue = Color(0xFF22D3EE);

  // ── Glass-параметры (используются GlassCard / GlassButton) ─────────────
  /// Полупрозрачный фон стеклянной карточки. Тонируется в bg-цвет.
  static const glassFill = Color(0x4D0F172A);          // 30% прозрачности тёмно-синий
  /// Бордер стекла — едва видимый белый, как «обводка по краю стекла».
  static const glassBorder = Color(0x33FFFFFF);        // 20% белый
  /// Сильный градиентный glow на акцентах.
  static const glowFill = Color(0x33A855F7);

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
        brightness: Brightness.dark,
        // Прозрачный scaffold — фон рисуется ниже (mesh + gradient).
        scaffoldBackgroundColor: Colors.transparent,
        fontFamily: 'Inter',
        colorScheme: ColorScheme.fromSeed(
          seedColor: primary,
          brightness: Brightness.dark,
          surface: bg,
          surfaceContainerHighest: glassFill,
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: text, fontSize: 14, height: 1.45),
          bodySmall: TextStyle(color: sub, fontSize: 12, height: 1.4),
          titleLarge: TextStyle(color: text, fontSize: 22, fontWeight: FontWeight.w700),
          titleMedium: TextStyle(color: text, fontSize: 16, fontWeight: FontWeight.w600),
          labelLarge: TextStyle(color: text, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: text, fontSize: 17, fontWeight: FontWeight.w700,
          ),
          iconTheme: IconThemeData(color: text),
        ),
        // Bottom-sheet тоже прозрачный — рендерим стекло сами в GlassSheet.
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: bg,
          contentTextStyle: TextStyle(color: text),
        ),
      );
}
