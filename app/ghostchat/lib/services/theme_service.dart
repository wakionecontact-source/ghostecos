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
enum ThemeStyle { vivid, minimal, mono, traditional }

String _styleToStr(ThemeStyle s) => switch (s) {
  ThemeStyle.minimal => 'minimal',
  ThemeStyle.mono => 'mono',
  ThemeStyle.traditional => 'traditional',
  ThemeStyle.vivid => 'vivid',
};

/// Дефолт для СВЕЖЕЙ установки (нет сохранённого _styleKey) — traditional,
/// "айфоновский" вид. У уже существующих пользователей _styleKey всегда
/// сохранён (даже 'vivid' записан явно при первом запуске), так что этот
/// дефолт их не затрагивает — см. ThemeService.load().
ThemeStyle _styleFromStr(String? s) => switch (s) {
  'minimal' => ThemeStyle.minimal,
  'mono' => ThemeStyle.mono,
  'vivid' => ThemeStyle.vivid,
  'traditional' => ThemeStyle.traditional,
  _ => ThemeStyle.traditional,
};

/// Имена всех 17 цветовых полей палитры — используются для UI-списка
/// поверхностей в редакторе своей темы и для (де)сериализации.
const List<String> paletteFieldNames = [
  'bg',
  'bgDeep',
  'surface',
  'border',
  'borderStrong',
  'primary',
  'primary2',
  'text',
  'sub',
  'muted',
  'green',
  'yellow',
  'red',
  'blue',
  'glassFill',
  'glassBorder',
  'glowFill',
];

/// "Ролевые" поля — их редактор всегда красит напрямую (нечего выводить).
/// Остальные 9 — "производные": при включённой умной краске пересчитываются
/// от ролевых, если конкретное поле не отвязано (detachedFields).
const Set<String> paletteRoleFields = {
  'bg',
  'primary',
  'primary2',
  'text',
  'green',
  'yellow',
  'red',
  'blue',
};
const Set<String> paletteDerivedFields = {
  'bgDeep',
  'surface',
  'border',
  'borderStrong',
  'sub',
  'muted',
  'glassFill',
  'glassBorder',
  'glowFill',
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

  /// Заменить ОДНО поле по имени, ничего не отвязывая — сырой сеттер,
  /// используется withField (+ отвязка) и точечными подвижками "соседних"
  /// поверхностей в ThemeService._applyFieldEdit (там отвязывать не нужно —
  /// сдвиг лёгкий и временный, а не ручная заморозка).
  Palette setFieldRaw(String field, Color color) {
    switch (field) {
      case 'bg':
        return copyWith(bg: color);
      case 'bgDeep':
        return copyWith(bgDeep: color);
      case 'surface':
        return copyWith(surface: color);
      case 'border':
        return copyWith(border: color);
      case 'borderStrong':
        return copyWith(borderStrong: color);
      case 'primary':
        return copyWith(primary: color);
      case 'primary2':
        return copyWith(primary2: color);
      case 'text':
        return copyWith(text: color);
      case 'sub':
        return copyWith(sub: color);
      case 'muted':
        return copyWith(muted: color);
      case 'green':
        return copyWith(green: color);
      case 'yellow':
        return copyWith(yellow: color);
      case 'red':
        return copyWith(red: color);
      case 'blue':
        return copyWith(blue: color);
      case 'glassFill':
        return copyWith(glassFill: color);
      case 'glassBorder':
        return copyWith(glassBorder: color);
      case 'glowFill':
        return copyWith(glowFill: color);
      default:
        throw ArgumentError('Неизвестное поле палитры: $field');
    }
  }

  /// Заменить ОДНО поле по имени — используется редактором (тап на
  /// поверхность → пикер → withField). Для производного поля при
  /// включённой умной краске правка = неявная отвязка (иначе следующий
  /// derivePalette() тут же затрёт ручную правку обратно).
  Palette withField(String field, Color color) {
    final next = setFieldRaw(field, color);
    if (paletteDerivedFields.contains(field) && smartPaint) {
      return next.copyWith(detachedFields: {...detachedFields, field});
    }
    return next;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'brightness': brightness == Brightness.dark ? 'dark' : 'light',
    'style': _styleToStr(style),
    'smartPaint': smartPaint,
    'detached': detachedFields.toList(),
    'colors': {for (final f in paletteFieldNames) f: this[f].toARGB32()},
  };

  static Palette fromJson(Map<String, dynamic> j) {
    final colors = (j['colors'] as Map).cast<String, dynamic>();
    Color c(String f) => Color(colors[f] as int);
    return Palette(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? '',
      subtitle: '',
      brightness: j['brightness'] == 'light'
          ? Brightness.light
          : Brightness.dark,
      style: _styleFromStr(j['style'] as String?),
      isCustom: true,
      smartPaint: (j['smartPaint'] as bool?) ?? true,
      detachedFields: ((j['detached'] as List?) ?? const [])
          .cast<String>()
          .toSet(),
      bg: c('bg'),
      bgDeep: c('bgDeep'),
      surface: c('surface'),
      border: c('border'),
      borderStrong: c('borderStrong'),
      primary: c('primary'),
      primary2: c('primary2'),
      text: c('text'),
      sub: c('sub'),
      muted: c('muted'),
      green: c('green'),
      yellow: c('yellow'),
      red: c('red'),
      blue: c('blue'),
      glassFill: c('glassFill'),
      glassBorder: c('glassBorder'),
      glowFill: c('glowFill'),
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
  // Обводки/контур стекла раньше были чистым нейтральным белым/чёрным —
  // никак не отражали цвета темы. Подмешиваем лёгкий оттенок акцента, чтобы
  // "стекло" выглядело частью темы, а не одинаковым серым обводом всегда.
  final borderTint = Color.lerp(overlayBase, p.primary, 0.20)!;
  Color d(String field, Color value) =>
      p.detachedFields.contains(field) ? p[field] : value;

  return p.copyWith(
    bgDeep: d(
      'bgDeep',
      Color.alphaBlend(
        (dark ? Colors.black : Colors.white).withValues(alpha: 0.16),
        p.bg,
      ),
    ),
    surface: d(
      'surface',
      Color.alphaBlend(
        overlayBase.withValues(alpha: 0.06),
        p.bg,
      ).withValues(alpha: 0.80),
    ),
    border: d('border', borderTint.withValues(alpha: 0.08)),
    borderStrong: d('borderStrong', borderTint.withValues(alpha: 0.13)),
    sub: d('sub', Color.lerp(p.text, p.bg, 0.35)!),
    muted: d('muted', Color.lerp(p.text, p.bg, 0.55)!),
    glassFill: d(
      'glassFill',
      Color.alphaBlend(
        overlayBase.withValues(alpha: 0.06),
        p.bg,
      ).withValues(alpha: dark ? 0.30 : 0.70),
    ),
    glassBorder: d('glassBorder', borderTint.withValues(alpha: 0.20)),
    glowFill: d('glowFill', p.primary.withValues(alpha: 0.20)),
  );
}

class ThemeService {
  ThemeService._();
  static final ThemeService instance = ThemeService._();

  /// Короткий доступ для мест вне glass.dart, где нужно спрятать
  /// контуры/свечение в минимализме ИЛИ монотоне (радар, чипы, вкладки и
  /// т.п.) — оба этих стиля плоские, отличаются только палитрой цветов.
  static bool get isMinimal => instance.styleNotifier.value != ThemeStyle.vivid;

  static const _key = 'gs_theme_preset_v1';
  static const _cornerKey = 'gs_corner_factor_v1';
  static const _avatarBannerBufferKey = 'gs_avatar_banner_buffer_v1';
  static const _meshKey = 'gs_mesh_enabled_v1';
  static const _meshSpeedKey = 'gs_mesh_speed_v1';
  static const _meshTouchReactionKey = 'gs_mesh_touch_reaction_v1';
  static const _preciseMessageTimeKey = 'gs_precise_message_time_v1';
  static const _liquidGlassKey = 'gs_liquid_glass_enabled_v1';
  static const _glassTintKey = 'gs_glass_tint_enabled_v1';
  static const _matteGlassKey = 'gs_matte_glass_enabled_v1';
  static const _styleKey = 'gs_theme_style_v1';
  static const _customKey = 'gs_custom_themes_v1';
  static const _listPlatesKey = 'gs_list_plates_v1';
  static const _navBarPlateKey = 'gs_navbar_plate_v1';
  static const _surfacesMigrationKey = 'gs_surfaces_migration_v2';
  static const _detailedDescriptionsKey = 'gs_detailed_descriptions_v1';
  static const maxCustomThemes = 100;

  /// Свои темы юзера — редактор своей темы (custom_theme_screen.dart) и
  /// сетка тем в настройках слушают этот нотифаер напрямую.
  final ValueNotifier<List<Palette>> customPresetsNotifier = ValueNotifier(
    const [],
  );
  List<Palette> get customPresets => customPresetsNotifier.value;
  bool get canCreateMoreCustomThemes => customPresets.length < maxCustomThemes;

  /// Перерисовка UI при смене темы — main подписывается ValueListenableBuilder.
  final ValueNotifier<Palette> notifier = ValueNotifier(_presets.first);

  /// Перерисовка UI при смене скругления — отдельный notifier, чтобы менять
  /// углы не заставляло пересобирать всё, что слушает palette.
  final ValueNotifier<double> cornerNotifier = ValueNotifier(GE.cornerFactor);

  /// Opaque neutral space around the avatar where the profile banner/background
  /// must not show through. The value is shared by profile screens and their
  /// compact previews.
  final ValueNotifier<double> avatarBannerBufferNotifier = ValueNotifier(20.0);

  /// Вкл/выкл анимированный mesh-фон (точки/линии/свечение) — для минимализма
  /// без "сияния". Выключено → плоская заливка GE.bg, тот же child поверх.
  final ValueNotifier<bool> meshNotifier = ValueNotifier(true);

  /// Скорость движения частиц mesh. 1.0 — базовая скорость, диапазон намеренно
  /// ограничен, чтобы ползунок не превращал фон в резкий или практически
  /// неподвижный.
  final ValueNotifier<double> meshSpeedNotifier = ValueNotifier(1.0);

  /// Включает реакцию mesh на палец и курсор. Сам фон при выключении
  /// продолжает двигаться, отключается только отталкивание и подсветка от
  /// точки касания.
  final ValueNotifier<bool> meshTouchReactionNotifier = ValueNotifier(true);

  /// Показывать секунды в timestamp сообщений вместо только часов и минут.
  final ValueNotifier<bool> preciseMessageTimeNotifier = ValueNotifier(false);

  /// Включает нативную линзу Liquid Glass на стеклянных поверхностях.
  final ValueNotifier<bool> liquidGlassNotifier = ValueNotifier(true);

  /// Цветной тинт поверхности стекла. По умолчанию выключен: под карточкой
  /// остаётся виден mesh, а поверхность даёт только тонкую кромку/рефракцию.
  final ValueNotifier<bool> glassTintNotifier = ValueNotifier(false);

  /// Дополнительный матовый слой (blur) поверх фоновой линзы. Независим от
  /// Liquid Glass: оба режима можно включить одновременно.
  final ValueNotifier<bool> matteGlassNotifier = ValueNotifier(false);

  /// Вкл/выкл фон-"табличку" у карточек-списков (Настройки, Разрешения и
  /// т.п. — GlassCard(isListSection: true)). Выключено по умолчанию везде —
  /// остаются только разделительные линии между строками, без заливки/блюра
  /// вокруг всего списка (см. GlassCard в glass.dart).
  final ValueNotifier<bool> listPlatesNotifier = ValueNotifier(false);

  /// Отдельный тумблер ТОЛЬКО для таблетки нижнего бара — не связан с
  /// listPlatesNotifier (который теперь управляет фоном везде ЕЩЁ, кроме
  /// бара). По просьбе Waki: раньше бар был завязан на общий тумблер, стало
  /// два независимых.
  final ValueNotifier<bool> navBarPlateNotifier = ValueNotifier(false);

  /// Показывать ли поясняющие подписи под названиями пунктов. Выключено по
  /// умолчанию: интерфейс остаётся компактным и показывает только чистые
  /// названия. Отдельные экраны слушают этот notifier и перестраиваются сразу.
  final ValueNotifier<bool> detailedDescriptionsNotifier = ValueNotifier(false);

  bool get showDetailedDescriptions => detailedDescriptionsNotifier.value;

  /// Стиль отрисовки (сияющий/минимализм) — см. ThemeStyle. Перерисовывает UI
  /// через тот же `notifier`, т.к. смена стиля переключает на «близнеца»
  /// текущей палитры (см. setStyle).
  final ValueNotifier<ThemeStyle> styleNotifier = ValueNotifier(
    ThemeStyle.vivid,
  );

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

  /// 'midnight_flat'/'midnight_mono'/'midnight_trad' → 'midnight' — общий
  /// id-«семьи» палитры вне зависимости от стиля, чтобы находить
  /// vivid/minimal/mono/traditional «близнецов».
  String _familyOf(String id) {
    if (id.endsWith('_flat')) return id.substring(0, id.length - 5);
    if (id.endsWith('_mono')) return id.substring(0, id.length - 5);
    if (id.endsWith('_trad')) return id.substring(0, id.length - 5);
    return id;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    await _loadCustomPresets(prefs);
    // Стиль считаем ДО выбора дефолтной темы: на свежей установке (нет ни
    // _key, ни _styleKey) дефолт должен быть парой "traditional + тема этого
    // же стиля", а не traditional-флаг при активной vivid-палитре.
    final style = _styleFromStr(prefs.getString(_styleKey));
    styleNotifier.value = style;
    final id = prefs.getString(_key);
    final found =
        (id != null ? findAnyPreset(id) : null) ??
        _presets.firstWhere(
          (p) => p.style == style,
          orElse: () => _presets.first,
        );
    _apply(found);
    final corner = prefs.getDouble(_cornerKey);
    if (corner != null) {
      GE.cornerFactor = corner.clamp(0.0, 1.0);
      cornerNotifier.value = GE.cornerFactor;
    }
    avatarBannerBufferNotifier.value =
        (prefs.getDouble(_avatarBannerBufferKey) ?? 20.0).clamp(0.0, 40.0);
    meshNotifier.value = prefs.getBool(_meshKey) ?? true;
    meshSpeedNotifier.value = (prefs.getDouble(_meshSpeedKey) ?? 1.0).clamp(
      0.25,
      2.0,
    );
    meshTouchReactionNotifier.value =
        prefs.getBool(_meshTouchReactionKey) ?? true;
    preciseMessageTimeNotifier.value =
        prefs.getBool(_preciseMessageTimeKey) ?? false;
    liquidGlassNotifier.value = prefs.getBool(_liquidGlassKey) ?? true;
    glassTintNotifier.value = prefs.getBool(_glassTintKey) ?? false;
    matteGlassNotifier.value = prefs.getBool(_matteGlassKey) ?? false;
    // В предыдущем варианте оба слоя по умолчанию были выключены, из-за чего
    // после обновления пропадали фон карточек и нижний бар. Один раз возвращаем
    // их в рабочее состояние; последующий выбор пользователя сохраняем.
    if (!(prefs.getBool(_surfacesMigrationKey) ?? false)) {
      listPlatesNotifier.value = true;
      navBarPlateNotifier.value = true;
      await prefs.setBool(_listPlatesKey, listPlatesNotifier.value);
      await prefs.setBool(_navBarPlateKey, navBarPlateNotifier.value);
      await prefs.setBool(_surfacesMigrationKey, true);
    } else {
      listPlatesNotifier.value = prefs.getBool(_listPlatesKey) ?? true;
      navBarPlateNotifier.value = prefs.getBool(_navBarPlateKey) ?? true;
    }
    detailedDescriptionsNotifier.value =
        prefs.getBool(_detailedDescriptionsKey) ?? false;
  }

  Future<void> _loadCustomPresets(SharedPreferences prefs) async {
    final raw = prefs.getString(_customKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as List;
      final list = <Palette>[];
      for (final m in decoded) {
        try {
          list.add(Palette.fromJson((m as Map).cast<String, dynamic>()));
        } catch (_) {
          // Одна битая/устаревшая тема (напр. после апдейта формата) — просто
          // пропускаем её, остальные свои темы всё равно должны загрузиться.
        }
      }
      customPresetsNotifier.value = list;
    } catch (_) {
      // Весь блок битый (не JSON-список и т.п.) — без своих тем в этот раз.
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

  Future<void> setMeshSpeed(double speed) async {
    final value = speed.clamp(0.25, 2.0).toDouble();
    meshSpeedNotifier.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_meshSpeedKey, value);
  }

  Future<void> setMeshTouchReaction(bool enabled) async {
    meshTouchReactionNotifier.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_meshTouchReactionKey, enabled);
  }

  Future<void> setPreciseMessageTime(bool enabled) async {
    preciseMessageTimeNotifier.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_preciseMessageTimeKey, enabled);
  }

  Future<void> setLiquidGlassEnabled(bool enabled) async {
    liquidGlassNotifier.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_liquidGlassKey, enabled);
  }

  Future<void> setGlassTintEnabled(bool enabled) async {
    glassTintNotifier.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_glassTintKey, enabled);
  }

  Future<void> setMatteGlassEnabled(bool enabled) async {
    matteGlassNotifier.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_matteGlassKey, enabled);
  }

  Future<void> setListPlatesEnabled(bool enabled) async {
    listPlatesNotifier.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_listPlatesKey, enabled);
  }

  Future<void> setNavBarPlateEnabled(bool enabled) async {
    navBarPlateNotifier.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_navBarPlateKey, enabled);
  }

  Future<void> setDetailedDescriptions(bool enabled) async {
    detailedDescriptionsNotifier.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_detailedDescriptionsKey, enabled);
  }

  /// Переключает стиль и сразу подменяет активную палитру на «близнеца» той
  /// же семьи в новом стиле (иначе экран остаётся с рассинхроном: стиль уже
  /// сменился, а карточки/кнопки ещё в старой палитре чужого стиля).
  /// При входе в минимализм заодно гасим mesh — сияющие точки противоречат
  /// самой идее режима; при входе в монотон заодно ставим максимальное
  /// скругление (45°) — фирменный вид монотона; при выходе из любого из
  /// них ничего не трогаем обратно (не навязываем).
  Future<void> setStyle(ThemeStyle style) async {
    if (style == styleNotifier.value) return;
    styleNotifier.value = style;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_styleKey, _styleToStr(style));

    // Свои темы не имеют vivid/minimal/mono «близнеца» — оставляем активной
    // как есть, иначе поиск твина среди встроенных пресетов ничего не
    // найдёт и молча подменит своя тему на случайный встроенный пресет.
    if (!notifier.value.isCustom) {
      final family = _familyOf(notifier.value.id);
      final wantId = switch (style) {
        ThemeStyle.minimal => '${family}_flat',
        ThemeStyle.mono => '${family}_mono',
        ThemeStyle.traditional => '${family}_trad',
        ThemeStyle.vivid => family,
      };
      final twin = _presets.firstWhere(
        (p) => p.id == wantId,
        orElse: () => _presets.firstWhere((p) => p.style == style),
      );
      _apply(twin);
      await prefs.setString(_key, twin.id);
    }

    if (style == ThemeStyle.minimal && meshNotifier.value) {
      await setMeshEnabled(false);
    }
    if (style == ThemeStyle.mono) {
      await setCornerFactor(1.0);
    }
  }

  Future<void> setPreset(String id) async {
    final p = findAnyPreset(id) ?? _presets.first;
    _apply(p);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, p.id);
    if (styleNotifier.value != p.style) {
      styleNotifier.value = p.style;
      await prefs.setString(_styleKey, _styleToStr(p.style));
    }
  }

  // ─── Свои темы (создание/правка) ───────────────────────────────────────
  //
  // Черновик появляется в сетке тем и применяется как активная тема СРАЗУ
  // при создании — редактор просто правит уже-активную палитру, поэтому
  // "свернуть панель и посмотреть UI" не требует отдельного preview-режима:
  // весь остальной интерфейс и так уже перекрашен в неё.

  int _idSeq = 0;
  String _newCustomId() =>
      'custom_${DateTime.now().millisecondsSinceEpoch}_${_idSeq++}';

  /// Новый черновик — стартовые цвета берём с ТЕКУЩЕЙ активной темы (даёт
  /// умной краске на чём сразу пересчитывать производные поля, а не
  /// начинать с нулевого/чёрного экрана). Возвращает null, если уже 100 тем.
  Future<Palette?> createDraftCustomTheme() async {
    if (!canCreateMoreCustomThemes) return null;
    final base = notifier.value;
    final draft = derivePalette(
      Palette(
        id: _newCustomId(),
        name: '',
        subtitle: '',
        brightness: base.brightness,
        style: base.style,
        isCustom: true,
        // Умный режим временно скрыт в редакторе и не включается в новых
        // темах: производные цвета задаются пользователем явно.
        smartPaint: false,
        bg: base.bg,
        bgDeep: base.bgDeep,
        surface: base.surface,
        border: base.border,
        borderStrong: base.borderStrong,
        primary: base.primary,
        primary2: base.primary2,
        text: base.text,
        sub: base.sub,
        muted: base.muted,
        green: base.green,
        yellow: base.yellow,
        red: base.red,
        blue: base.blue,
        glassFill: base.glassFill,
        glassBorder: base.glassBorder,
        glowFill: base.glowFill,
      ),
    );
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
      for (final p in customPresets)
        if (p.id == updated.id) updated else p,
    ];
    // Применяем к живой теме СРАЗУ (синхронно, до await), а не после
    // сохранения на диск — иначе два быстрых подряд редактирования могут
    // гонкой откатить экран на более старую правку, а "живой" предпросмотр
    // ждал бы записи на диск без причины.
    if (notifier.value.id == updated.id) _apply(updated);
    await _saveCustomPresets();
  }

  /// Перекрасить одну поверхность своей темы. У производного поля при
  /// включённой умной краске это неявно отвязывает его (см. Palette.withField).
  Future<void> setCustomField(String id, String field, Color color) async {
    final p = customPresets.firstWhere(
      (x) => x.id == id,
      orElse: () => throw StateError('нет такой темы'),
    );
    await _replaceCustom(_applyFieldEdit(p, field, color));
  }

  /// Общая логика правки одного поля — переиспользуется setCustomField
  /// (сохраняет) и previewCustomField (только живой предпросмотр).
  ///
  /// Ролевые поля (bg/primary/...) просто пересчитывают derivePalette как
  /// раньше — все 9 производных подстраиваются под новые ролевые цвета.
  ///
  /// Производные поверхности (border/surface/...) раньше при ручной правке
  /// просто "отвязывались" сами по себе — остальные поверхности оставались
  /// на месте, из-за чего тема расходилась (правишь одно — остальное не
  /// реагирует). Теперь первая ручная правка ещё не отвязанной поверхности
  /// сдвигает светлоту ВСЕХ остальных ещё не отвязанных поверхностей на ту
  /// же дельту — они остаются согласованы друг с другом, а не расходятся.
  Palette _applyFieldEdit(Palette p, String field, Color color) {
    final isSurfaceEdit =
        paletteDerivedFields.contains(field) &&
        p.smartPaint &&
        !p.detachedFields.contains(field);
    if (!isSurfaceEdit) {
      return derivePalette(p.withField(field, color));
    }
    final auto = derivePalette(p);
    final delta =
        HSLColor.fromColor(color).lightness -
        HSLColor.fromColor(auto[field]).lightness;
    var next = p.withField(field, color); // это и есть отвязка правленого поля
    for (final sibling in paletteDerivedFields) {
      if (sibling == field || next.detachedFields.contains(sibling)) continue;
      final hsl = HSLColor.fromColor(auto[sibling]);
      final shifted = hsl
          .withLightness((hsl.lightness + delta).clamp(0.0, 1.0))
          .toColor();
      // setFieldRaw, а не withField — сдвиг соседей не должен их отвязывать,
      // иначе первая же правка поверхности замораживает вообще все.
      next = next.setFieldRaw(sibling, shifted);
    }
    return next;
  }

  /// Живое превью правки поля БЕЗ записи на диск — для перетаскивания в
  /// пикере цвета (там много промежуточных тиков за секунду, писать на диск
  /// на каждый — лишняя нагрузка/лаг). Применяет к живой теме и превью сразу,
  /// как setCustomField, просто не персистит. Финальный цвет фиксируется
  /// отдельным вызовом setCustomField при закрытии пикера (Применить/Отмена).
  void previewCustomField(String id, String field, Color color) {
    final p = customPresets.firstWhere(
      (x) => x.id == id,
      orElse: () => throw StateError('нет такой темы'),
    );
    final updated = _applyFieldEdit(p, field, color);
    customPresetsNotifier.value = [
      for (final x in customPresets)
        if (x.id == updated.id) updated else x,
    ];
    if (notifier.value.id == updated.id) _apply(updated);
  }

  /// Явный тумблер "своя/авто" у производной поверхности — включение
  /// (detached=true) замораживает её текущее значение под ручную правку,
  /// выключение возвращает под пересчёт умной краски (текущая ручная
  /// правка теряется — то и ожидается от "снова авто").
  Future<void> setFieldDetached(String id, String field, bool detached) async {
    final p = customPresets.firstWhere(
      (x) => x.id == id,
      orElse: () => throw StateError('нет такой темы'),
    );
    final nextDetached = {...p.detachedFields};
    if (detached) {
      nextDetached.add(field);
    } else {
      nextDetached.remove(field);
    }
    await _replaceCustom(
      derivePalette(p.copyWith(detachedFields: nextDetached)),
    );
  }

  /// Тумблер умной краски. Включение — чистый пересчёт всех производных
  /// полей заново (отвязки сбрасываются, иначе "включил и ничего не
  /// изменилось" выглядело бы как баг).
  Future<void> setCustomSmartPaint(String id, bool enabled) async {
    final p = customPresets.firstWhere(
      (x) => x.id == id,
      orElse: () => throw StateError('нет такой темы'),
    );
    var next = p.copyWith(smartPaint: enabled);
    if (enabled) next = next.copyWith(detachedFields: const {});
    await _replaceCustom(derivePalette(next));
  }

  Future<void> renameCustomTheme(String id, String name) async {
    final p = customPresets.firstWhere(
      (x) => x.id == id,
      orElse: () => throw StateError('нет такой темы'),
    );
    await _replaceCustom(p.copyWith(name: name.trim()));
  }

  Future<void> deleteCustomTheme(String id) async {
    final wasActive = notifier.value.id == id;
    customPresetsNotifier.value = customPresets
        .where((p) => p.id != id)
        .toList();
    await _saveCustomPresets();
    if (wasActive) {
      await setPreset(
        _presets.firstWhere((p) => p.style == styleNotifier.value).id,
      );
    }
  }

  /// Клон своей темы — пипетка «Создать новую тему» в контекстном меню.
  Future<Palette?> duplicateCustomTheme(String id) async {
    if (!canCreateMoreCustomThemes) return null;
    final src = findAnyPreset(id);
    if (src == null) return null;
    final baseName = src.name.isEmpty ? 'Без названия' : src.name;
    final dup = src.copyWith(
      id: _newCustomId(),
      name: '$baseName (копия)',
      isCustom: true,
    );
    customPresetsNotifier.value = [...customPresets, dup];
    await _saveCustomPresets();
    return dup;
  }

  /// Пипетка «Перенести в другую тему» — вся палитра источника заменяет
  /// палитру приёмника (id/имя приёмника не трогаем).
  Future<void> transferPaletteTo({
    required String fromId,
    required String toId,
  }) async {
    final src = findAnyPreset(fromId);
    final dst = customPresets.firstWhere(
      (x) => x.id == toId,
      orElse: () => throw StateError('нет такой темы'),
    );
    if (src == null) return;
    final merged = dst.copyWith(
      bg: src.bg,
      bgDeep: src.bgDeep,
      surface: src.surface,
      border: src.border,
      borderStrong: src.borderStrong,
      primary: src.primary,
      primary2: src.primary2,
      text: src.text,
      sub: src.sub,
      muted: src.muted,
      green: src.green,
      yellow: src.yellow,
      red: src.red,
      blue: src.blue,
      glassFill: src.glassFill,
      glassBorder: src.glassBorder,
      glowFill: src.glowFill,
      smartPaint: src.smartPaint,
      detachedFields: src.detachedFields,
    );
    await _replaceCustom(derivePalette(merged));
  }

  /// Пипетка «Перенести цвет поверхности» — только одно поле.
  Future<void> transferSurfaceTo({
    required String fromId,
    required String toId,
    required String field,
  }) async {
    final src = findAnyPreset(fromId);
    final dst = customPresets.firstWhere(
      (x) => x.id == toId,
      orElse: () => throw StateError('нет такой темы'),
    );
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

  Future<void> setAvatarBannerBuffer(double buffer) async {
    final clamped = buffer.clamp(0.0, 40.0).toDouble();
    avatarBannerBufferNotifier.value = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_avatarBannerBufferKey, clamped);
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
final List<Palette> _presets = [
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
  ..._monoPresets,
  ..._traditionalPresets,
];

// ─── Традиционный ────────────────────────────────────────────────────────
// "Айфоновский" стиль — те же 7 палитр, что и у минимализма (тот же набор
// цветов, тот же принцип "непрозрачные плоские поверхности вместо стекла"),
// разница целиком в отрисовке (glass.dart): вместо BackdropFilter-блюра и
// цветного glow — мягкая нейтральная тень под карточками/кнопками, как в
// настоящем iOS (см. _traditional флаг в glass.dart).
final List<Palette> _traditionalPresets = [
  Palette(
    id: 'midnight_trad',
    name: 'Полночь',
    subtitle: 'Глубокий фиолет, традиционный',
    brightness: Brightness.dark,
    style: ThemeStyle.traditional,
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
    id: 'eclipse_trad',
    name: 'Затмение',
    subtitle: 'Графит и сталь, традиционный',
    brightness: Brightness.dark,
    style: ThemeStyle.traditional,
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
    id: 'sunset_trad',
    name: 'Закат',
    subtitle: 'Тёплый закат, традиционный',
    brightness: Brightness.dark,
    style: ThemeStyle.traditional,
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
    id: 'forest_trad',
    name: 'Лес',
    subtitle: 'Изумруд и мох, традиционный',
    brightness: Brightness.dark,
    style: ThemeStyle.traditional,
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
    id: 'aurora_trad',
    name: 'Аврора',
    subtitle: 'Северное сияние, традиционный',
    brightness: Brightness.dark,
    style: ThemeStyle.traditional,
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
    id: 'ivory_trad',
    name: 'Слоновая кость',
    subtitle: 'Светлая, традиционный',
    brightness: Brightness.light,
    style: ThemeStyle.traditional,
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
    id: 'dull_trad',
    name: 'Тусклая',
    subtitle: 'Только серый и чёрный, традиционный',
    brightness: Brightness.dark,
    style: ThemeStyle.traditional,
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

// ─── Монотон ──────────────────────────────────────────────────────────────
// Третий стиль отрисовки — буквально два цвета (фон + один "чернильный" тон
// вместо акцента), ничего не должно выделяться цветом отдельно. Считается
// автоматически через derivePalette (та же "умная краска", что и у своих
// тем) от фона+акцента каждой из 7 семей — так гарантированно внутренне
// согласовано, без ручного подбора 17 полей на каждый вариант.
Palette _makeMonoVariant({
  required String id,
  required String name,
  required String subtitle,
  required Color bg,
  required Color accent,
  required Brightness brightness,
}) {
  final dark = brightness == Brightness.dark;
  // Лёгкий намёк на характер семьи (оттенок акцента), но сильно
  // десатурированный и доведённый до контрастной светлоты — единственный
  // "не фон" цвет во всей палитре.
  final hsl = HSLColor.fromColor(accent);
  final ink = hsl
      .withSaturation((hsl.saturation * 0.18).clamp(0.0, 1.0))
      .withLightness(dark ? 0.92 : 0.16)
      .toColor();
  final seed = Palette(
    id: id,
    name: name,
    subtitle: subtitle,
    brightness: brightness,
    style: ThemeStyle.mono,
    bg: bg,
    bgDeep: bg,
    surface: bg,
    border: bg,
    borderStrong: bg,
    primary: ink,
    primary2: ink,
    text: ink,
    sub: ink,
    muted: ink,
    green: ink,
    yellow: ink,
    red: ink,
    blue: ink,
    glassFill: bg,
    glassBorder: bg,
    glowFill: bg,
  );
  return derivePalette(seed);
}

final List<Palette> _monoPresets = [
  _makeMonoVariant(
    id: 'midnight_mono',
    name: 'Полночь',
    subtitle: 'Монотон — только фон и текст',
    bg: const Color(0xFF020617),
    accent: const Color(0xFFA855F7),
    brightness: Brightness.dark,
  ),
  _makeMonoVariant(
    id: 'eclipse_mono',
    name: 'Затмение',
    subtitle: 'Монотон — только фон и текст',
    bg: const Color(0xFF0A0A0A),
    accent: const Color(0xFF60A5FA),
    brightness: Brightness.dark,
  ),
  _makeMonoVariant(
    id: 'sunset_mono',
    name: 'Закат',
    subtitle: 'Монотон — только фон и текст',
    bg: const Color(0xFF1A0A14),
    accent: const Color(0xFFF97316),
    brightness: Brightness.dark,
  ),
  _makeMonoVariant(
    id: 'forest_mono',
    name: 'Лес',
    subtitle: 'Монотон — только фон и текст',
    bg: const Color(0xFF051811),
    accent: const Color(0xFF10B981),
    brightness: Brightness.dark,
  ),
  _makeMonoVariant(
    id: 'aurora_mono',
    name: 'Аврора',
    subtitle: 'Монотон — только фон и текст',
    bg: const Color(0xFF0A0E2E),
    accent: const Color(0xFF22D3EE),
    brightness: Brightness.dark,
  ),
  _makeMonoVariant(
    id: 'ivory_mono',
    name: 'Слоновая кость',
    subtitle: 'Монотон — только фон и текст',
    bg: const Color(0xFFFAF7F2),
    accent: const Color(0xFF7C3AED),
    brightness: Brightness.light,
  ),
  _makeMonoVariant(
    id: 'dull_mono',
    name: 'Тусклая',
    subtitle: 'Монотон — только фон и текст',
    bg: const Color(0xFF0B0B0C),
    accent: const Color(0xFF9CA3AF),
    brightness: Brightness.dark,
  ),
];
