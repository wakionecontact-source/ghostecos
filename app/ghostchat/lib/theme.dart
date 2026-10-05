// Палитра и тема экосистемы Ghost. Поля цвета — static (НЕ const), чтобы
// ThemeService мог переключать палитру на лету.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'services/performance_service.dart';

class GE {
  // ── Бэкенд ─────────────────────────────────────────────────────────────
  static const baseUrl = 'https://ghostecos.duckdns.org';
  static const apiChat = '$baseUrl/api/chat';
  static const apiSoc = '$baseUrl/api/soc';
  // Профиль/контакты "core"-идентичности (display_name, about, avatar_bg_color,
  // glow_color) живут на bare /api (backchat/routers/users.py), отдельно от
  // /api/chat и /api/soc.
  static const apiCore = '$baseUrl/api';
  static const apiBots = '$baseUrl/api/bots';
  static const wsUrl = 'wss://ghostecos.duckdns.org/api/soc/ws';
  static const appName = 'GhostChat';

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

  // ── Скругление углов — настраивается слайдером (Внешний вид → Скругление).
  // cornerFactor 0.0 = острые углы, 1.0 = максимально круглые. Максимумы
  // подобраны так, чтобы factor=0.5 (дефолт) давал ТЕ ЖЕ значения, что были
  // здесь раньше как const — существующий вид не меняется, пока юзер сам не
  // подвинет слайдер.
  static const _radiusSmMax = 20.0;
  static const _radiusMdMax = 32.0;
  static const _radiusLgMax = 44.0;
  static double cornerFactor = 0.5;
  static double get radiusSm => _radiusSmMax * cornerFactor;
  static double get radiusMd => _radiusMdMax * cornerFactor;
  static double get radiusLg => _radiusLgMax * cornerFactor;

  static ThemeData theme() => ThemeData(
    useMaterial3: true,
    brightness: currentBrightness,
    scaffoldBackgroundColor: Colors.transparent,
    fontFamily: 'Inter',
    // Плавные переходы между экранами — мягкий zoom+fade (M3), премиально.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _GhostPageTransitionsBuilder(),
        TargetPlatform.iOS: _GhostPageTransitionsBuilder(),
      },
    ),
    // В профиле энергосбережения убираем ripple/splash: это отдельные
    // короткоживущие saveLayer-анимации, которые не покрывались настройкой
    // длительности переходов.
    splashFactory:
        PerformanceService.instance.animationQuality == AnimationQuality.best
        ? InkRipple.splashFactory
        : NoSplash.splashFactory,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primary,
      brightness: currentBrightness,
      surface: bg,
      surfaceContainerHighest: glassFill,
    ),
    textTheme: TextTheme(
      bodyMedium: TextStyle(color: text, fontSize: 14, height: 1.45),
      bodySmall: TextStyle(color: sub, fontSize: 12, height: 1.4),
      titleLarge: TextStyle(
        color: text,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: TextStyle(
        color: text,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      labelLarge: TextStyle(
        color: text,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        color: text,
        fontSize: 17,
        fontWeight: FontWeight.w700,
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

/// Единая точка управления переходами экранов. В «Лучшем» сохраняем текущий
/// zoom+fade Material 3, «Обычное» использует дешёвый fade-up, а «Без
/// анимаций» сразу показывает новый экран.
class _GhostPageTransitionsBuilder extends PageTransitionsBuilder {
  const _GhostPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    switch (PerformanceService.instance.animationQuality) {
      case AnimationQuality.best:
        return (const ZoomPageTransitionsBuilder()).buildTransitions(
          route,
          context,
          animation,
          secondaryAnimation,
          child,
        );
      case AnimationQuality.standard:
        return (const FadeUpwardsPageTransitionsBuilder()).buildTransitions(
          route,
          context,
          animation,
          secondaryAnimation,
          child,
        );
      case AnimationQuality.none:
        return child;
    }
  }
}

double _relLuminance(Color c) {
  double ch(int v) {
    final s = v / 255.0;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  final argb = c.toARGB32();
  return 0.2126 * ch((argb >> 16) & 0xFF) +
      0.7152 * ch((argb >> 8) & 0xFF) +
      0.0722 * ch(argb & 0xFF);
}

double _contrastRatio(Color a, Color b) {
  final la = _relLuminance(a), lb = _relLuminance(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// Цвет текста/иконки поверх заливки [fill] — выбирает GE.text или GE.bg,
/// смотря какой реально контрастен. GE.text годится "по умолчанию" (в
/// обычных темах primary/red — насыщенный акцент, GE.text — почти белый,
/// это давно "случайно работало"), но ломается в монотоне, где primary и
/// text — буквально один и тот же "чернильный" цвет: текст кнопки сливался
/// бы с её же заливкой. Единственный предохранитель на этот случай.
Color onColor(Color fill) {
  final textC = _contrastRatio(GE.text, fill);
  final bgC = _contrastRatio(GE.bg, fill);
  return textC >= bgC ? GE.text : GE.bg;
}
