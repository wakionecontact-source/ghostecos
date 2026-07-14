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

/// Стиль отрисовки — ось, независимая от выбора палитры (см. meshNotifier
/// для похожего паттерна). vivid — текущее «жидкое стекло» (blur, градиенты,
/// свечение). minimal — плоские карточки/кнопки без blur и glow, для тех кто
/// просил "абсолютный минимализм". У каждой палитры есть своя пара (vivid +
/// minimal), см. _presets ниже — переключение стиля выбирает подходящего
/// «близнеца» той же палитры, а не произвольную тему.
enum ThemeStyle { vivid, minimal }

class Palette {
  final String id;
  final String name;
  final String subtitle;
  final Brightness brightness;
  final ThemeStyle style;

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
    this.style = ThemeStyle.vivid,
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

  /// Короткий доступ для мест вне glass.dart, где нужно спрятать
  /// контуры/свечение в минимализме (радар, чипы, вкладки и т.п.).
  static bool get isMinimal => instance.styleNotifier.value == ThemeStyle.minimal;

  static const _key = 'gs_theme_preset_v1';
  static const _cornerKey = 'gs_corner_factor_v1';
  static const _meshKey = 'gs_mesh_enabled_v1';
  static const _styleKey = 'gs_theme_style_v1';

  /// Перерисовка UI при смене темы — main подписывается ValueListenableBuilder.
  final ValueNotifier<Palette> notifier = ValueNotifier(_presets.first);

  /// Перерисовка UI при смене скругления — отдельный notifier, чтобы менять
  /// углы не заставляло пересобирать всё, что слушает palette.
  final ValueNotifier<double> cornerNotifier = ValueNotifier(GE.cornerFactor);

  /// Вкл/выкл анимированный mesh-фон (точки/линии/свечение) — для минимализма
  /// без "сияния". Выключено → плоская заливка GE.bg, тот же child поверх.
  final ValueNotifier<bool> meshNotifier = ValueNotifier(true);

  /// Стиль отрисовки (сияющий/минимализм) — см. ThemeStyle. Перерисовывает UI
  /// через тот же `notifier`, т.к. смена стиля переключает на «близнеца»
  /// текущей палитры (см. setStyle).
  final ValueNotifier<ThemeStyle> styleNotifier = ValueNotifier(ThemeStyle.vivid);

  /// Доступ ко всем доступным темам.
  List<Palette> get presets => _presets;

  /// Только темы текущего стиля — так «Тема» в Настройках показывает лишь
  /// подходящих «близнецов», а не все 12 вперемешку.
  List<Palette> get presetsForCurrentStyle =>
      _presets.where((p) => p.style == styleNotifier.value).toList();

  /// 'midnight_flat' → 'midnight' — общий id-«семьи» палитры вне зависимости
  /// от стиля, чтобы находить vivid/minimal пару друг друга.
  String _familyOf(String id) =>
      id.endsWith('_flat') ? id.substring(0, id.length - 5) : id;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_key);
    final found = _presets.firstWhere(
      (p) => p.id == id,
      orElse: () => _presets.first,
    );
    _apply(found);
    final corner = prefs.getDouble(_cornerKey);
    if (corner != null) {
      GE.cornerFactor = corner.clamp(0.0, 1.0);
      cornerNotifier.value = GE.cornerFactor;
    }
    meshNotifier.value = prefs.getBool(_meshKey) ?? true;
    final styleStr = prefs.getString(_styleKey);
    styleNotifier.value = styleStr == 'minimal' ? ThemeStyle.minimal : ThemeStyle.vivid;
  }

  Future<void> setMeshEnabled(bool enabled) async {
    meshNotifier.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_meshKey, enabled);
  }

  /// Переключает стиль и сразу подменяет активную палитру на «близнеца» той
  /// же семьи в новом стиле (иначе экран остаётся с рассинхроном: стиль уже
  /// сменился, а карточки/кнопки ещё в старой палитре чужого стиля).
  /// При входе в минимализм заодно гасим mesh — сияющие точки противоречат
  /// самой идее режима; при выходе mesh не трогаем (не навязываем обратно).
  Future<void> setStyle(ThemeStyle style) async {
    if (style == styleNotifier.value) return;
    styleNotifier.value = style;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_styleKey, style == ThemeStyle.minimal ? 'minimal' : 'vivid');

    final family = _familyOf(notifier.value.id);
    final wantId = style == ThemeStyle.minimal ? '${family}_flat' : family;
    final twin = _presets.firstWhere(
      (p) => p.id == wantId,
      orElse: () => _presets.firstWhere((p) => p.style == style),
    );
    _apply(twin);
    await prefs.setString(_key, twin.id);

    if (style == ThemeStyle.minimal && meshNotifier.value) {
      await setMeshEnabled(false);
    }
  }

  Future<void> setPreset(String id) async {
    final p = _presets.firstWhere((x) => x.id == id, orElse: () => _presets.first);
    _apply(p);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, id);
    if (styleNotifier.value != p.style) {
      styleNotifier.value = p.style;
      await prefs.setString(_styleKey, p.style == ThemeStyle.minimal ? 'minimal' : 'vivid');
    }
  }

  Future<void> setCornerFactor(double factor) async {
    final clamped = factor.clamp(0.0, 1.0);
    GE.cornerFactor = clamped;
    cornerNotifier.value = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_cornerKey, clamped);
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
  Palette(
    id: 'dull',
    name: 'Тусклая',
    subtitle: 'Только серый и чёрный — никакого цвета',
    brightness: Brightness.dark,
    bg: Color(0xFF0B0B0C),
    bgDeep: Color(0xFF050506),
    surface: Color(0xCC1A1A1C),
    border: Color(0x14FFFFFF),
    borderStrong: Color(0x21FFFFFF),
    primary: Color(0xFF9CA3AF),
    primary2: Color(0xFF6B7280),
    text: Color(0xFFF4F4F5),
    sub: Color(0xFF9CA3AF),
    muted: Color(0xFF52525B),
    // Статусные цвета оставлены узнаваемыми (приглушены, не в полную яркость)
    // — иначе индикатор "онлайн"/ошибка теряет смысл в чисто серой палитре.
    green: Color(0xFF7DA88C),
    yellow: Color(0xFFBFAE7A),
    red: Color(0xFFB08585),
    blue: Color(0xFF8AA0B0),
    glassFill: Color(0x4D1A1A1C),
    glassBorder: Color(0x33FFFFFF),
    glowFill: Color(0x229CA3AF),
  ),

  // ─── Минимализм ── те же 7 палитр, без blur/градиентов/свечения ──────────
  // bgDeep = bg (нет вертикального градиента фона), glassFill — сплошная
  // непрозрачная заливка (карточка не «стеклянная», а плоская), glowFill —
  // прозрачный (GlassCard/GlassButton в glass.dart не рисуют свечение и blur
  // вовсе при ThemeStyle.minimal, но обнуляем и тут для консистентности).
  Palette(
    id: 'midnight_flat',
    name: 'Полночь',
    subtitle: 'Глубокий фиолет, минимализм',
    brightness: Brightness.dark,
    style: ThemeStyle.minimal,
    bg: Color(0xFF020617),
    bgDeep: Color(0xFF020617),
    surface: Color(0xFF0F172A),
    border: Color(0x1FFFFFFF),
    borderStrong: Color(0x30FFFFFF),
    primary: Color(0xFFA855F7),
    primary2: Color(0xFF7C3AED),
    text: Color(0xFFF1F5F9),
    sub: Color(0xFF94A3B8),
    muted: Color(0xFF64748B),
    green: Color(0xFF4ADE80),
    yellow: Color(0xFFFBBF24),
    red: Color(0xFFF87171),
    blue: Color(0xFF22D3EE),
    glassFill: Color(0xFF0F172A),
    glassBorder: Color(0x30FFFFFF),
    glowFill: Color(0x00A855F7),
  ),
  Palette(
    id: 'eclipse_flat',
    name: 'Затмение',
    subtitle: 'Графит и сталь, минимализм',
    brightness: Brightness.dark,
    style: ThemeStyle.minimal,
    bg: Color(0xFF0A0A0A),
    bgDeep: Color(0xFF0A0A0A),
    surface: Color(0xFF161616),
    border: Color(0x1FFFFFFF),
    borderStrong: Color(0x30FFFFFF),
    primary: Color(0xFF60A5FA),
    primary2: Color(0xFF2563EB),
    text: Color(0xFFFAFAFA),
    sub: Color(0xFF9CA3AF),
    muted: Color(0xFF6B7280),
    green: Color(0xFF34D399),
    yellow: Color(0xFFFCD34D),
    red: Color(0xFFEF4444),
    blue: Color(0xFF38BDF8),
    glassFill: Color(0xFF161616),
    glassBorder: Color(0x30FFFFFF),
    glowFill: Color(0x0060A5FA),
  ),
  Palette(
    id: 'sunset_flat',
    name: 'Закат',
    subtitle: 'Тёплый закат, минимализм',
    brightness: Brightness.dark,
    style: ThemeStyle.minimal,
    bg: Color(0xFF1A0A14),
    bgDeep: Color(0xFF1A0A14),
    surface: Color(0xFF2A1418),
    border: Color(0x1FFFFFFF),
    borderStrong: Color(0x30FFFFFF),
    primary: Color(0xFFF97316),
    primary2: Color(0xFFEC4899),
    text: Color(0xFFFFF1E6),
    sub: Color(0xFFFCA5A5),
    muted: Color(0xFFC084FC),
    green: Color(0xFFFCD34D),
    yellow: Color(0xFFFBBF24),
    red: Color(0xFFEF4444),
    blue: Color(0xFFFBBF24),
    glassFill: Color(0xFF2A1418),
    glassBorder: Color(0x30FFFFFF),
    glowFill: Color(0x00F97316),
  ),
  Palette(
    id: 'forest_flat',
    name: 'Лес',
    subtitle: 'Изумруд и мох, минимализм',
    brightness: Brightness.dark,
    style: ThemeStyle.minimal,
    bg: Color(0xFF051811),
    bgDeep: Color(0xFF051811),
    surface: Color(0xFF0E2A1F),
    border: Color(0x1FFFFFFF),
    borderStrong: Color(0x30FFFFFF),
    primary: Color(0xFF10B981),
    primary2: Color(0xFF059669),
    text: Color(0xFFECFDF5),
    sub: Color(0xFF6EE7B7),
    muted: Color(0xFF34D399),
    green: Color(0xFF6EE7B7),
    yellow: Color(0xFFFDE68A),
    red: Color(0xFFFCA5A5),
    blue: Color(0xFF67E8F9),
    glassFill: Color(0xFF0E2A1F),
    glassBorder: Color(0x30FFFFFF),
    glowFill: Color(0x0010B981),
  ),
  Palette(
    id: 'aurora_flat',
    name: 'Аврора',
    subtitle: 'Северное сияние, минимализм',
    brightness: Brightness.dark,
    style: ThemeStyle.minimal,
    bg: Color(0xFF0A0E2E),
    bgDeep: Color(0xFF0A0E2E),
    surface: Color(0xFF0E1547),
    border: Color(0x1FFFFFFF),
    borderStrong: Color(0x30FFFFFF),
    primary: Color(0xFF22D3EE),
    primary2: Color(0xFFA855F7),
    text: Color(0xFFE0F2FE),
    sub: Color(0xFF7DD3FC),
    muted: Color(0xFF818CF8),
    green: Color(0xFF6EE7B7),
    yellow: Color(0xFFFBBF24),
    red: Color(0xFFF87171),
    blue: Color(0xFF22D3EE),
    glassFill: Color(0xFF0E1547),
    glassBorder: Color(0x30FFFFFF),
    glowFill: Color(0x0022D3EE),
  ),
  Palette(
    id: 'ivory_flat',
    name: 'Слоновая кость',
    subtitle: 'Светлая, минимализм',
    brightness: Brightness.light,
    style: ThemeStyle.minimal,
    bg: Color(0xFFFAF7F2),
    bgDeep: Color(0xFFFAF7F2),
    surface: Color(0xFFFFFFFF),
    border: Color(0x1F000000),
    borderStrong: Color(0x40000000),
    primary: Color(0xFF7C3AED),
    primary2: Color(0xFF5B21B6),
    text: Color(0xFF0F172A),
    sub: Color(0xFF475569),
    muted: Color(0xFF94A3B8),
    green: Color(0xFF16A34A),
    yellow: Color(0xFFCA8A04),
    red: Color(0xFFDC2626),
    blue: Color(0xFF0284C7),
    glassFill: Color(0xFFFFFFFF),
    glassBorder: Color(0x40000000),
    glowFill: Color(0x007C3AED),
  ),
  Palette(
    id: 'dull_flat',
    name: 'Тусклая',
    subtitle: 'Только серый и чёрный, минимализм',
    brightness: Brightness.dark,
    style: ThemeStyle.minimal,
    bg: Color(0xFF0B0B0C),
    bgDeep: Color(0xFF0B0B0C),
    surface: Color(0xFF1A1A1C),
    border: Color(0x1FFFFFFF),
    borderStrong: Color(0x30FFFFFF),
    primary: Color(0xFF9CA3AF),
    primary2: Color(0xFF6B7280),
    text: Color(0xFFF4F4F5),
    sub: Color(0xFF9CA3AF),
    muted: Color(0xFF52525B),
    green: Color(0xFF7DA88C),
    yellow: Color(0xFFBFAE7A),
    red: Color(0xFFB08585),
    blue: Color(0xFF8AA0B0),
    glassFill: Color(0xFF1A1A1C),
    glassBorder: Color(0x30FFFFFF),
    glowFill: Color(0x009CA3AF),
  ),
];
