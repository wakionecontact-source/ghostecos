// ThemeService — управление палитрой Ghost. 5 встроенных пресетов
// + возможность добавить кастомный «свой акцент» в M8.
//
// Темы переключаются на лету: ValueNotifier перерисовывает MaterialApp,
// статические поля GE подменяются на новые цвета.
//
// Пресеты:
//  1. midnight  — глубокая ночь (текущий тёмно-фиолетовый, дефолт)
//  2. eclipse   — графит + холодная сталь (для свайп-эстетов)
//  3. sunset    — тёплый закат (оранж + малиновый)
//  4. forest    — зелёный лес (изумруд + мох)
//  5. aurora    — северное сияние (cyan + magenta gradient)
//  6. ivory     — светлая (молочная, для тех кто не любит тёмное)

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';

class Palette {
  final String id;
  final String name;
  final String subtitle;
  final Brightness brightness;

  final Color bg;
  final Color bgDeep;
  final Color surface;
  final Color border;
  final Color borderStrong;
  final Color primary;
  final Color primary2;
  final Color text;
  final Color sub;
  final Color muted;
  final Color green;
  final Color yellow;
  final Color red;
  final Color blue;
  final Color glassFill;
  final Color glassBorder;
  final Color glowFill;

  const Palette({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.brightness,
    required this.bg,
    required this.bgDeep,
    required this.surface,
    required this.border,
    required this.borderStrong,
    required this.primary,
    required this.primary2,
    required this.text,
    required this.sub,
    required this.muted,
    required this.green,
    required this.yellow,
    required this.red,
    required this.blue,
    required this.glassFill,
    required this.glassBorder,
    required this.glowFill,
  });
}

class ThemeService {
  ThemeService._();
  static final ThemeService instance = ThemeService._();
  static const _key = 'gs_theme_preset_v1';

  /// Перерисовка UI при смене темы — main подписывается ValueListenableBuilder.
  final ValueNotifier<Palette> notifier = ValueNotifier(_presets.first);

  /// Доступ ко всем доступным темам.
  List<Palette> get presets => _presets;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_key);
    final found = _presets.firstWhere(
      (p) => p.id == id,
      orElse: () => _presets.first,
    );
    _apply(found);
  }

  Future<void> setPreset(String id) async {
    final p = _presets.firstWhere((x) => x.id == id, orElse: () => _presets.first);
    _apply(p);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, id);
  }

  void _apply(Palette p) {
    GE.bg = p.bg;
    GE.bgDeep = p.bgDeep;
    GE.surface = p.surface;
    GE.border = p.border;
    GE.borderStrong = p.borderStrong;
    GE.primary = p.primary;
    GE.primary2 = p.primary2;
    GE.text = p.text;
    GE.sub = p.sub;
    GE.muted = p.muted;
    GE.green = p.green;
    GE.yellow = p.yellow;
    GE.red = p.red;
    GE.blue = p.blue;
    GE.glassFill = p.glassFill;
    GE.glassBorder = p.glassBorder;
    GE.glowFill = p.glowFill;
    GE.currentBrightness = p.brightness;
    notifier.value = p;
  }
}

// ─── Пресеты ────────────────────────────────────────────────────────────
const List<Palette> _presets = [
  Palette(
    id: 'midnight',
    name: 'Полночь',
    subtitle: 'Глубокий фиолет, дефолт Ghost',
    brightness: Brightness.dark,
    bg: Color(0xFF020617),
    bgDeep: Color(0xFF060A1A),
    surface: Color(0xCC0F172A),
    border: Color(0x14FFFFFF),
    borderStrong: Color(0x21FFFFFF),
    primary: Color(0xFFA855F7),
    primary2: Color(0xFF7C3AED),
    text: Color(0xFFF1F5F9),
    sub: Color(0xFF94A3B8),
    muted: Color(0xFF64748B),
    green: Color(0xFF4ADE80),
    yellow: Color(0xFFFBBF24),
    red: Color(0xFFF87171),
    blue: Color(0xFF22D3EE),
    glassFill: Color(0x4D0F172A),
    glassBorder: Color(0x33FFFFFF),
    glowFill: Color(0x33A855F7),
  ),
  Palette(
    id: 'eclipse',
    name: 'Затмение',
    subtitle: 'Графит и сталь — для минималистов',
    brightness: Brightness.dark,
    bg: Color(0xFF0A0A0A),
    bgDeep: Color(0xFF050505),
    surface: Color(0xCC161616),
    border: Color(0x14FFFFFF),
    borderStrong: Color(0x21FFFFFF),
    primary: Color(0xFF60A5FA),
    primary2: Color(0xFF2563EB),
    text: Color(0xFFFAFAFA),
    sub: Color(0xFF9CA3AF),
    muted: Color(0xFF6B7280),
    green: Color(0xFF34D399),
    yellow: Color(0xFFFCD34D),
    red: Color(0xFFEF4444),
    blue: Color(0xFF38BDF8),
    glassFill: Color(0x4D1F1F1F),
    glassBorder: Color(0x33FFFFFF),
    glowFill: Color(0x3360A5FA),
  ),
  Palette(
    id: 'sunset',
    name: 'Закат',
    subtitle: 'Тёплый закат над морем',
    brightness: Brightness.dark,
    bg: Color(0xFF1A0A14),
    bgDeep: Color(0xFF120508),
    surface: Color(0xCC2A1418),
    border: Color(0x14FFFFFF),
    borderStrong: Color(0x21FFFFFF),
    primary: Color(0xFFF97316),
    primary2: Color(0xFFEC4899),
    text: Color(0xFFFFF1E6),
    sub: Color(0xFFFCA5A5),
    muted: Color(0xFFC084FC),
    green: Color(0xFFFCD34D),
    yellow: Color(0xFFFBBF24),
    red: Color(0xFFEF4444),
    blue: Color(0xFFFBBF24),
    glassFill: Color(0x4D3A1F2D),
    glassBorder: Color(0x33FFFFFF),
    glowFill: Color(0x33F97316),
  ),
  Palette(
    id: 'forest',
    name: 'Лес',
    subtitle: 'Изумруд и мох — медитативная',
    brightness: Brightness.dark,
    bg: Color(0xFF051811),
    bgDeep: Color(0xFF020F09),
    surface: Color(0xCC0E2A1F),
    border: Color(0x14FFFFFF),
    borderStrong: Color(0x21FFFFFF),
    primary: Color(0xFF10B981),
    primary2: Color(0xFF059669),
    text: Color(0xFFECFDF5),
    sub: Color(0xFF6EE7B7),
    muted: Color(0xFF34D399),
    green: Color(0xFF6EE7B7),
    yellow: Color(0xFFFDE68A),
    red: Color(0xFFFCA5A5),
    blue: Color(0xFF67E8F9),
    glassFill: Color(0x4D113D2A),
    glassBorder: Color(0x33FFFFFF),
    glowFill: Color(0x3310B981),
  ),
  Palette(
    id: 'aurora',
    name: 'Аврора',
    subtitle: 'Северное сияние — cyan + magenta',
    brightness: Brightness.dark,
    bg: Color(0xFF0A0E2E),
    bgDeep: Color(0xFF050720),
    surface: Color(0xCC0E1547),
    border: Color(0x14FFFFFF),
    borderStrong: Color(0x21FFFFFF),
    primary: Color(0xFF22D3EE),
    primary2: Color(0xFFA855F7),
    text: Color(0xFFE0F2FE),
    sub: Color(0xFF7DD3FC),
    muted: Color(0xFF818CF8),
    green: Color(0xFF6EE7B7),
    yellow: Color(0xFFFBBF24),
    red: Color(0xFFF87171),
    blue: Color(0xFF22D3EE),
    glassFill: Color(0x4D131E5E),
    glassBorder: Color(0x33FFFFFF),
    glowFill: Color(0x3322D3EE),
  ),
  Palette(
    id: 'ivory',
    name: 'Слоновая кость',
    subtitle: 'Светлая — для дневного режима',
    brightness: Brightness.light,
    bg: Color(0xFFFAF7F2),
    bgDeep: Color(0xFFF3EFE7),
    surface: Color(0xCCFFFFFF),
    border: Color(0x14000000),
    borderStrong: Color(0x33000000),
    primary: Color(0xFF7C3AED),
    primary2: Color(0xFF5B21B6),
    text: Color(0xFF0F172A),
    sub: Color(0xFF475569),
    muted: Color(0xFF94A3B8),
    green: Color(0xFF16A34A),
    yellow: Color(0xFFCA8A04),
    red: Color(0xFFDC2626),
    blue: Color(0xFF0284C7),
    glassFill: Color(0xB3FFFFFF),
    glassBorder: Color(0x4D7C3AED),
    glowFill: Color(0x337C3AED),
  ),
];
