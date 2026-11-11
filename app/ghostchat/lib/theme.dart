// Палитра и тема экосистемы Ghost. Цвета — константы единой палитры
// (лендинг / v2 social). Переключение тем отключено (ThemeService.themesEnabled).
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'design/app_palette.dart';
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

  // ── Цвета: единая палитра (лендинг / v2 social) ────────────────────────
  static const Color bg = AppPalette.bg;
  static const Color bgDeep = AppPalette.bgDeep;
  static const Color surface = AppPalette.surface;
  static const Color surfaceElevated = AppPalette.surfaceElevated;
  static const Color surfacePressed = AppPalette.surfacePressed;
  static const Color border = AppPalette.border;
  static const Color borderStrong = AppPalette.borderStrong;
  static const Color primary = AppPalette.accent;
  static const Color primary2 = AppPalette.accentDeep;
  static const Color accentSoft = AppPalette.accentSoft;
  static const Color onAccent = AppPalette.onAccent;
  static const Color text = AppPalette.text;
  static const Color sub = AppPalette.textSecondary;
  static const Color muted = AppPalette.textMuted;
  static const Color green = AppPalette.success;
  static const Color yellow = AppPalette.warning;
  static const Color red = AppPalette.danger;
  static const Color blue = AppPalette.info;

  // ── Реакции соцсети ────────────────────────────────────────────────────
  static const Color reactionHeart = AppPalette.reactionHeart;
  static const Color reactionFire = AppPalette.reactionFire;
  static const Color reactionLaugh = AppPalette.reactionLaugh;
  static const Color reactionSad = AppPalette.reactionSad;
  static const Color reactionClap = AppPalette.reactionClap;
  static const Color reactionEyes = AppPalette.reactionEyes;
  static const Color scrim = AppPalette.scrim;
  static const Color shadow = AppPalette.shadow;

  // ── Оверлеи и скримы (замена Colors.white*/Colors.black*) ───────────────
  static const Color overlayWeak = AppPalette.overlayWeak;
  static const Color overlayMedium = AppPalette.overlayMedium;
  static const Color overlayStrong = AppPalette.overlayStrong;
  static const Color scrimFaint = AppPalette.scrimFaint;
  static const Color scrimDim = AppPalette.scrimDim;
  static const Color scrimMedium = AppPalette.scrimMedium;
  static const Color scrimSoft = AppPalette.scrimSoft;
  static const Color scrimStrong = AppPalette.scrimStrong;
  static const Color scrimHeavy = AppPalette.scrimHeavy;
  static const Color scrimDeep = AppPalette.scrimDeep;

  // ── Glass-параметры (только точечные поверхности) ──────────────────────
  static const Color glassFill = AppPalette.glassFill;
  static const Color glassBorder = AppPalette.glassBorder;
  static const Color glowFill = AppPalette.glow;
  static const Brightness currentBrightness = Brightness.dark;

  /// Размытие фона за стеклянной поверхностью (sigma для BackdropFilter).
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
      surfaceContainerHighest: surfaceElevated,
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
    // Редизайн: разделительных линий нет нигде.
    dividerTheme: const DividerThemeData(color: Colors.transparent),
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
