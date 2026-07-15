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

import 'dart:convert';
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

/// Имена всех 17 цветовых полей палитры — используются для UI-списка
/// поверхностей в редакторе своей темы и для (де)сериализации.
const List<String> paletteFieldNames = [
  'bg', 'bgDeep', 'surface', 'border', 'borderStrong',
  'primary', 'primary2', 'text', 'sub', 'muted',
  'green', 'yellow', 'red', 'blue',
  'glassFill', 'glassBorder', 'glowFill',
];

/// "Ролевые" поля — их редактор всегда красит напрямую (нечего выводить).
/// Остальные 9 — "производные": при включённой умной краске пересчитываются
/// от ролевых, если конкретное поле не отвязано (detachedFields).
const Set<String> paletteRoleFields = {
  'bg', 'primary', 'primary2', 'text', 'green', 'yellow', 'red', 'blue',
};
const Set<String> paletteDerivedFields = {
  'bgDeep', 'surface', 'border', 'borderStrong', 'sub', 'muted',
  'glassFill', 'glassBorder', 'glowFill',
};

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

  /// Своя тема юзера (не встроенный пресет) — влияет на то, что можно с
  /// ней делать (переименовать/удалить/настроить у встроенных нельзя).
  final bool isCustom;
  /// "Умная краска" — производные поля (paletteDerivedFields) пересчитываются
  /// от ролевых при каждой правке, кроме отвязанных (см. detachedFields).
  final bool smartPaint;
  /// Производные поля, которые юзер перекрасил вручную — умная краска их
  /// больше не трогает, пока не отвязка не снята (retach отсутствует по
  /// дизайну: перекраска ролевого поля их не пересчитает, но повторная
  /// смена смарт-режима заново включает пересчёт для всех).
  final Set<String> detachedFields;

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
    this.isCustom = false,
    this.smartPaint = true,
    this.detachedFields = const {},
  });

  Color operator [](String field) => switch (field) {
        'bg' => bg,
        'bgDeep' => bgDeep,
        'surface' => surface,
        'border' => border,
        'borderStrong' => borderStrong,
        'primary' => primary,
        'primary2' => primary2,
        'text' => text,
        'sub' => sub,
        'muted' => muted,
        'green' => green,
        'yellow' => yellow,
        'red' => red,
        'blue' => blue,
        'glassFill' => glassFill,
        'glassBorder' => glassBorder,
        'glowFill' => glowFill,
        _ => throw ArgumentError('Неизвестное поле палитры: $field'),
      };

  Palette copyWith({
    String? id,
    String? name,
    String? subtitle,
    Brightness? brightness,
    ThemeStyle? style,
    Color? bg,
    Color? bgDeep,
    Color? surface,
    Color? border,
    Color? borderStrong,
    Color? primary,
    Color? primary2,
    Color? text,
    Color? sub,
    Color? muted,
    Color? green,
    Color? yellow,
    Color? red,
    Color? blue,
    Color? glassFill,
    Color? glassBorder,
    Color? glowFill,
    bool? isCustom,
    bool? smartPaint,
    Set<String>? detachedFields,
  }) {
    return Palette(
      id: id ?? this.id,
      name: name ?? this.name,
      subtitle: subtitle ?? this.subtitle,
      brightness: brightness ?? this.brightness,
      style: style ?? this.style,
      bg: bg ?? this.bg,
      bgDeep: bgDeep ?? this.bgDeep,
      surface: surface ?? this.surface,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      primary: primary ?? this.primary,
      primary2: primary2 ?? this.primary2,
      text: text ?? this.text,
      sub: sub ?? this.sub,
      muted: muted ?? this.muted,
      green: green ?? this.green,
      yellow: yellow ?? this.yellow,
      red: red ?? this.red,
      blue: blue ?? this.blue,
      glassFill: glassFill ?? this.glassFill,
      glassBorder: glassBorder ?? this.glassBorder,
      glowFill: glowFill ?? this.glowFill,
      isCustom: isCustom ?? this.isCustom,
      smartPaint: smartPaint ?? this.smartPaint,
      detachedFields: detachedFields ?? this.detachedFields,
    );
  }

  /// Заменить ОДНО поле по имени — используется редактором (тап на
  /// поверхность → пикер → withField). Для производного поля при
  /// включённой умной краске правка = неявная отвязка (иначе следующий
  /// derivePalette() тут же затрёт ручную правку обратно).
  Palette withField(String field, Color color) {
    final nextDetached = paletteDerivedFields.contains(field) && smartPaint
        ? ({...detachedFields, field})
        : detachedFields;
    switch (field) {
      case 'bg': return copyWith(bg: color, detachedFields: nextDetached);
      case 'bgDeep': return copyWith(bgDeep: color, detachedFields: nextDetached);
      case 'surface': return copyWith(surface: color, detachedFields: nextDetached);
      case 'border': return copyWith(border: color, detachedFields: nextDetached);
      case 'borderStrong': return copyWith(borderStrong: color, detachedFields: nextDetached);
      case 'primary': return copyWith(primary: color, detachedFields: nextDetached);
      case 'primary2': return copyWith(primary2: color, detachedFields: nextDetached);
      case 'text': return copyWith(text: color, detachedFields: nextDetached);
      case 'sub': return copyWith(sub: color, detachedFields: nextDetached);
      case 'muted': return copyWith(muted: color, detachedFields: nextDetached);
      case 'green': return copyWith(green: color, detachedFields: nextDetached);
      case 'yellow': return copyWith(yellow: color, detachedFields: nextDetached);
      case 'red': return copyWith(red: color, detachedFields: nextDetached);
      case 'blue': return copyWith(blue: color, detachedFields: nextDetached);
      case 'glassFill': return copyWith(glassFill: color, detachedFields: nextDetached);
      case 'glassBorder': return copyWith(glassBorder: color, detachedFields: nextDetached);
      case 'glowFill': return copyWith(glowFill: color, detachedFields: nextDetached);
      default: throw ArgumentError('Неизвестное поле палитры: $field');
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'brightness': brightness == Brightness.dark ? 'dark' : 'light',
        'style': style == ThemeStyle.minimal ? 'minimal' : 'vivid',
        'smartPaint': smartPaint,
        'detached': detachedFields.toList(),
        'colors': {
          for (final f in paletteFieldNames) f: this[f].toARGB32(),
        },
      };

  static Palette fromJson(Map<String, dynamic> j) {
    final colors = (j['colors'] as Map).cast<String, dynamic>();
    Color c(String f) => Color(colors[f] as int);
    return Palette(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? '',
      subtitle: '',
      brightness: j['brightness'] == 'light' ? Brightness.light : Brightness.dark,
      style: j['style'] == 'minimal' ? ThemeStyle.minimal : ThemeStyle.vivid,
      isCustom: true,
      smartPaint: (j['smartPaint'] as bool?) ?? true,
      detachedFields: ((j['detached'] as List?) ?? const []).cast<String>().toSet(),
      bg: c('bg'), bgDeep: c('bgDeep'), surface: c('surface'),
      border: c('border'), borderStrong: c('borderStrong'),
      primary: c('primary'), primary2: c('primary2'),
      text: c('text'), sub: c('sub'), muted: c('muted'),
      green: c('green'), yellow: c('yellow'), red: c('red'), blue: c('blue'),
      glassFill: c('glassFill'), glassBorder: c('glassBorder'), glowFill: c('glowFill'),
    );
  }
}

/// Пересчитать производные поля (paletteDerivedFields) от ролевых
/// (paletteRoleFields), пропуская отвязанные — общая "умная краска"-логика.
/// Формулы зеркалят соотношения встроенных пресетов (см. _presets ниже):
/// border/borderStrong/glassBorder — полупрозрачный белый/чёрный оверлей в
/// зависимости от brightness, sub/muted — шаги затемнения text→bg,
/// bgDeep/surface — шаги от bg, glowFill — акцент на просвет.
Palette derivePalette(Palette p) {
  if (!p.smartPaint) return p;
  final dark = p.brightness == Brightness.dark;
  final overlayBase = dark ? Colors.white : Colors.black;
  Color d(String field, Color value) =>
      p.detachedFields.contains(field) ? p[field] : value;

  return p.copyWith(
    bgDeep: d('bgDeep', Color.alphaBlend(
        (dark ? Colors.black : Colors.white).withValues(alpha: 0.16), p.bg)),
    surface: d('surface', Color.alphaBlend(
        overlayBase.withValues(alpha: 0.06), p.bg).withValues(alpha: 0.80)),
    border: d('border', overlayBase.withValues(alpha: 0.08)),
    borderStrong: d('borderStrong', overlayBase.withValues(alpha: 0.13)),
    sub: d('sub', Color.lerp(p.text, p.bg, 0.35)!),
    muted: d('muted', Color.lerp(p.text, p.bg, 0.55)!),
    glassFill: d('glassFill', Color.alphaBlend(
        overlayBase.withValues(alpha: 0.06), p.bg).withValues(alpha: dark ? 0.30 : 0.70)),
    glassBorder: d('glassBorder', overlayBase.withValues(alpha: 0.20)),
    glowFill: d('glowFill', p.primary.withValues(alpha: 0.20)),
  );
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
  static const _customKey = 'gs_custom_themes_v1';
  static const maxCustomThemes = 100;

  /// Свои темы юзера — редактор своей темы (custom_theme_screen.dart) и
  /// сетка тем в настройках слушают этот нотифаер напрямую.
  final ValueNotifier<List<Palette>> customPresetsNotifier = ValueNotifier(const []);
  List<Palette> get customPresets => customPresetsNotifier.value;
  bool get canCreateMoreCustomThemes => customPresets.length < maxCustomThemes;

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

  /// Только темы текущего стиля (встроенные + свои) — так «Тема» в
  /// Настройках показывает лишь подходящих «близнецов», а не всё сразу.
  /// Свои темы — в конце списка, сразу после встроенных.
  List<Palette> get presetsForCurrentStyle => [
        ..._presets.where((p) => p.style == styleNotifier.value),
        ...customPresets.where((p) => p.style == styleNotifier.value),
      ];

  Palette? findAnyPreset(String id) {
    for (final p in _presets) {
      if (p.id == id) return p;
    }
    for (final p in customPresets) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 'midnight_flat' → 'midnight' — общий id-«семьи» палитры вне зависимости
  /// от стиля, чтобы находить vivid/minimal пару друг друга.
  String _familyOf(String id) =>
      id.endsWith('_flat') ? id.substring(0, id.length - 5) : id;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    await _loadCustomPresets(prefs);
    final id = prefs.getString(_key);
    final found = (id != null ? findAnyPreset(id) : null) ?? _presets.first;
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

  Future<void> _loadCustomPresets(SharedPreferences prefs) async {
    final raw = prefs.getString(_customKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = (jsonDecode(raw) as List)
          .cast<Map>()
          .map((m) => Palette.fromJson(m.cast<String, dynamic>()))
          .toList();
      customPresetsNotifier.value = list;
    } catch (_) {
      // Битый JSON (напр. после сбойного апдейта формата) — не роняем
      // загрузку темы, просто без своих тем в этот раз.
    }
  }

  Future<void> _saveCustomPresets() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _customKey,
      jsonEncode(customPresets.map((p) => p.toJson()).toList()),
    );
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
    final p = findAnyPreset(id) ?? _presets.first;
    _apply(p);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, p.id);
    if (styleNotifier.value != p.style) {
      styleNotifier.value = p.style;
      await prefs.setString(_styleKey, p.style == ThemeStyle.minimal ? 'minimal' : 'vivid');
    }
  }

  // ─── Свои темы (создание/правка) ───────────────────────────────────────
  //
  // Черновик появляется в сетке тем и применяется как активная тема СРАЗУ
  // при создании — редактор просто правит уже-активную палитру, поэтому
  // "свернуть панель и посмотреть UI" не требует отдельного preview-режима:
  // весь остальной интерфейс и так уже перекрашен в неё.

  String _newCustomId() =>
      'custom_${DateTime.now().millisecondsSinceEpoch}';

  /// Новый черновик — стартовые цвета берём с ТЕКУЩЕЙ активной темы (даёт
  /// умной краске на чём сразу пересчитывать производные поля, а не
  /// начинать с нулевого/чёрного экрана). Возвращает null, если уже 100 тем.
  Future<Palette?> createDraftCustomTheme() async {
    if (!canCreateMoreCustomThemes) return null;
    final base = notifier.value;
    final draft = derivePalette(Palette(
      id: _newCustomId(),
      name: '',
      subtitle: '',
      brightness: base.brightness,
      style: base.style,
      isCustom: true,
      smartPaint: true,
      bg: base.bg, bgDeep: base.bgDeep, surface: base.surface,
      border: base.border, borderStrong: base.borderStrong,
      primary: base.primary, primary2: base.primary2,
      text: base.text, sub: base.sub, muted: base.muted,
      green: base.green, yellow: base.yellow, red: base.red, blue: base.blue,
      glassFill: base.glassFill, glassBorder: base.glassBorder, glowFill: base.glowFill,
    ));
    customPresetsNotifier.value = [...customPresets, draft];
    await _saveCustomPresets();
    await setPreset(draft.id);
    return draft;
  }

  /// Открыть существующую свою тему для правки — делает её активной, чтобы
  /// редактор (и весь остальной UI за ним) сразу показывал её вживую.
  Future<void> openCustomThemeForEdit(String id) => setPreset(id);

  Future<void> _replaceCustom(Palette updated) async {
    customPresetsNotifier.value = [
      for (final p in customPresets) if (p.id == updated.id) updated else p,
    ];
    await _saveCustomPresets();
    if (notifier.value.id == updated.id) _apply(updated);
  }

  /// Перекрасить одну поверхность своей темы. У производного поля при
  /// включённой умной краске это неявно отвязывает его (см. Palette.withField).
  Future<void> setCustomField(String id, String field, Color color) async {
    final p = customPresets.firstWhere((x) => x.id == id, orElse: () => throw StateError('нет такой темы'));
    await _replaceCustom(derivePalette(p.withField(field, color)));
  }

  /// Явный тумблер "своя/авто" у производной поверхности — включение
  /// (detached=true) замораживает её текущее значение под ручную правку,
  /// выключение возвращает под пересчёт умной краски (текущая ручная
  /// правка теряется — то и ожидается от "снова авто").
  Future<void> setFieldDetached(String id, String field, bool detached) async {
    final p = customPresets.firstWhere((x) => x.id == id, orElse: () => throw StateError('нет такой темы'));
    final nextDetached = {...p.detachedFields};
    if (detached) {
      nextDetached.add(field);
    } else {
      nextDetached.remove(field);
    }
    await _replaceCustom(derivePalette(p.copyWith(detachedFields: nextDetached)));
  }

  /// Тумблер умной краски. Включение — чистый пересчёт всех производных
  /// полей заново (отвязки сбрасываются, иначе "включил и ничего не
  /// изменилось" выглядело бы как баг).
  Future<void> setCustomSmartPaint(String id, bool enabled) async {
    final p = customPresets.firstWhere((x) => x.id == id, orElse: () => throw StateError('нет такой темы'));
    var next = p.copyWith(smartPaint: enabled);
    if (enabled) next = next.copyWith(detachedFields: const {});
    await _replaceCustom(derivePalette(next));
  }

  Future<void> renameCustomTheme(String id, String name) async {
    final p = customPresets.firstWhere((x) => x.id == id, orElse: () => throw StateError('нет такой темы'));
    await _replaceCustom(p.copyWith(name: name.trim()));
  }

  Future<void> deleteCustomTheme(String id) async {
    final wasActive = notifier.value.id == id;
    customPresetsNotifier.value =
        customPresets.where((p) => p.id != id).toList();
    await _saveCustomPresets();
    if (wasActive) {
      await setPreset(_presets.firstWhere((p) => p.style == styleNotifier.value).id);
    }
  }

  /// Клон своей темы — пипетка «Создать новую тему» в контекстном меню.
  Future<Palette?> duplicateCustomTheme(String id) async {
    if (!canCreateMoreCustomThemes) return null;
    final src = findAnyPreset(id);
    if (src == null) return null;
    final dup = src.copyWith(id: _newCustomId(), name: '', isCustom: true);
    customPresetsNotifier.value = [...customPresets, dup];
    await _saveCustomPresets();
    return dup;
  }

  /// Пипетка «Перенести в другую тему» — вся палитра источника заменяет
  /// палитру приёмника (id/имя приёмника не трогаем).
  Future<void> transferPaletteTo({required String fromId, required String toId}) async {
    final src = findAnyPreset(fromId);
    final dst = customPresets.firstWhere((x) => x.id == toId, orElse: () => throw StateError('нет такой темы'));
    if (src == null) return;
    final merged = dst.copyWith(
      bg: src.bg, bgDeep: src.bgDeep, surface: src.surface,
      border: src.border, borderStrong: src.borderStrong,
      primary: src.primary, primary2: src.primary2,
      text: src.text, sub: src.sub, muted: src.muted,
      green: src.green, yellow: src.yellow, red: src.red, blue: src.blue,
      glassFill: src.glassFill, glassBorder: src.glassBorder, glowFill: src.glowFill,
      smartPaint: src.smartPaint, detachedFields: src.detachedFields,
    );
    await _replaceCustom(merged);
  }

  /// Пипетка «Перенести цвет поверхности» — только одно поле.
  Future<void> transferSurfaceTo({
    required String fromId,
    required String toId,
    required String field,
  }) async {
    final src = findAnyPreset(fromId);
    final dst = customPresets.firstWhere((x) => x.id == toId, orElse: () => throw StateError('нет такой темы'));
    if (src == null) return;
    await _replaceCustom(derivePalette(dst.withField(field, src[field])));
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
