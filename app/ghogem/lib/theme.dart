// GhostGem — FLAT, иконки вместо эмодзи, Manrope + JetBrains Mono
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class GG {
  static const baseUrl = 'https://ghostecos.duckdns.org';
  static const apiGhogem = '$baseUrl/ghogem-api';
  static const wsGhogem = 'wss://ghostecos.duckdns.org/ghogem-api/ws/chat';
  static const appName = 'GhostGem';

  // Flat palette — чуть светлее surfaces для контраста без границ
  static Color bg = const Color(0xFF0A0710);
  static Color bgDeep = const Color(0xFF110C1A);
  static Color bgCard = const Color(0xFF1A1430);
  static Color surface = const Color(0xFF211A3A);
  static Color surface2 = const Color(0xFF2A2244);
  static Color surface3 = const Color(0xFF2F2648);
  static Color paper = const Color(0xFFefe9f5);
  static Color dim = const Color(0xFFc7bfd2);
  static Color muted = const Color(0xFF8f86a0);
  static Color faint = const Color(0xFF6b6580);
  static Color violet = const Color(0xFF7c3aed);
  static Color iris = const Color(0xFFa78bfa);
  static Color text = const Color(0xFFefe9f5);
  static Color sub = const Color(0xFFc7bfd2);
  static Color green = const Color(0xFF4ADE80);
  static Color yellow = const Color(0xFFFBBF24);
  static Color red = const Color(0xFFF87171);
  static Color blue = const Color(0xFF22D3EE);

  static Color border = Colors.transparent;
  static Color borderStrong = Colors.transparent;
  static Color glassFill = surface;
  static Color glassBorder = Colors.transparent;
  static Color glowFill = Colors.transparent;
  static const glassBlur = 0.0;
  static const glassStroke = 0.0;
  static double cornerFactor = 0.5;
  static const _rSmMax = 14.0, _rMdMax = 18.0, _rLgMax = 22.0;
  static double get rSm => _rSmMax * cornerFactor;
  static double get rMd => _rMdMax * cornerFactor;
  static double get rLg => _rLgMax * cornerFactor;

  static ThemeData theme() {
    final manrope = GoogleFonts.manropeTextTheme;
    final mono = GoogleFonts.jetBrainsMonoTextTheme;
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(
        seedColor: violet,
        brightness: Brightness.dark,
        surface: bg,
        onSurface: paper,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bgDeep,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.manrope(color: text, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.4),
        iconTheme: IconThemeData(color: text, size: 20),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF1E1B2E),
        contentTextStyle: GoogleFonts.manrope(color: text, fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
    return base.copyWith(
      textTheme: manrope(base.textTheme).copyWith(
        bodyMedium: GoogleFonts.manrope(color: text, fontSize: 14, height: 1.55, fontWeight: FontWeight.w400),
        bodySmall: GoogleFonts.manrope(color: sub, fontSize: 12, height: 1.45),
        titleLarge: GoogleFonts.manrope(color: text, fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.5),
        titleMedium: GoogleFonts.manrope(color: text, fontSize: 15, fontWeight: FontWeight.w700),
        labelLarge: GoogleFonts.manrope(color: text, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.1),
        bodyLarge: GoogleFonts.manrope(color: text, fontSize: 14, height: 1.5),
      ).apply(bodyColor: text, displayColor: text),
    );
  }

  // mono style helper
  static TextStyle monoStyle({double size=11, Color? color, FontWeight? weight}) =>
      GoogleFonts.jetBrainsMono(color: color ?? faint, fontSize: size, fontWeight: weight ?? FontWeight.w500, letterSpacing: 0.2);
}

Color onColor(Color fill) {
  double lum(Color c) {
    double ch(int v) {
      final s = v / 255.0;
      return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
    }
    final a = c.toARGB32();
    return 0.2126 * ch((a >> 16) & 0xFF) + 0.7152 * ch((a >> 8) & 0xFF) + 0.0722 * ch(a & 0xFF);
  }
  final la = lum(GG.text), lb = lum(fill);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  final ct = (hi + 0.05) / (lo + 0.05);
  final cb = (lum(GG.bg) + 0.05) / (lo + 0.05);
  return ct >= cb ? GG.text : GG.bg;
}
