// Редактор своей темы — правка живьём (весь остальной UI за этим экраном
// уже перекрашен в редактируемую тему, см. ThemeService.createDraftCustomTheme/
// openCustomThemeForEdit). Свернуть экран (кнопка назад) не спрашивает
// "сохранить?" — черновик уже сохранён на каждую правку, "Далее" только
// просит имя и явно завершает тему.
//
// Без анимированного mesh-фона нарочно: это утилитарный экран с частыми
// перерисовками (drag по SV-квадрату/hue-слайдеру), лишняя фоновая анимация
// тут не нужна и на слабых/подсевших устройствах может тормозить открытие
// пикера цвета.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme.dart';
import '../services/theme_service.dart';
import '../widgets/glass.dart';
import '../widgets/color_picker_panel.dart';
import '../widgets/emoji_text.dart';
import 'settings_screen.dart' show pickSourceCustomTheme;

/// Относительная яркость канала (WCAG) — общий шаг для контраста ниже.
double _channelLum(int v) {
  final s = v / 255.0;
  return s <= 0.03928
      ? s / 12.92
      : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
}

double _relativeLuminance(Color c) {
  final argb = c.toARGB32();
  final r = _channelLum((argb >> 16) & 0xFF);
  final g = _channelLum((argb >> 8) & 0xFF);
  final b = _channelLum(argb & 0xFF);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// Коэффициент контраста двух цветов по WCAG (1 = одинаковые, 21 = чёрный/белый).
/// Единственный «предохранитель» на случай, когда юзер задаёт свою палитру с
/// почти нечитаемым текстом (напр. светлый текст на светлом фоне) — мы не
/// правим его цвета молча, а показываем предупреждение в редакторе.
double _contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

class _FieldInfo {
  final String key;
  final String label;
  final String hint;
  final bool derived;
  const _FieldInfo(this.key, this.label, this.hint, {this.derived = false});
}

const List<_FieldInfo> _fields = [
  _FieldInfo('bg', 'Фон', 'Основной фон экранов'),
  _FieldInfo('primary', 'Акцент', 'Кнопки, ссылки, активные элементы'),
  _FieldInfo('primary2', 'Акцент 2', 'Второй цвет градиента вместе с акцентом'),
  _FieldInfo('text', 'Текст', 'Основной текст'),
  _FieldInfo('green', 'Успех', 'Онлайн, доставлено, успешные действия'),
  _FieldInfo('yellow', 'Предупреждение', 'Предупреждения, ожидание'),
  _FieldInfo('red', 'Ошибка', 'Ошибки, удаление, паник-режим'),
  _FieldInfo('blue', 'Инфо', 'Информационные значки и ссылки'),
  _FieldInfo(
    'bgDeep',
    'Фон (глубокий)',
    'Градиент под основным фоном',
    derived: true,
  ),
  _FieldInfo(
    'surface',
    'Поверхность карточек',
    'Фон карточек, полей ввода',
    derived: true,
  ),
  _FieldInfo(
    'border',
    'Разделитель',
    'Тонкие линии между блоками',
    derived: true,
  ),
  _FieldInfo(
    'borderStrong',
    'Разделитель (акцент)',
    'Выделенные границы',
    derived: true,
  ),
  _FieldInfo(
    'sub',
    'Текст (вторичный)',
    'Подписи, время, статусы',
    derived: true,
  ),
  _FieldInfo(
    'muted',
    'Текст (приглушённый)',
    'Плейсхолдеры, неактивные элементы',
    derived: true,
  ),
  _FieldInfo(
    'glassFill',
    'Заливка стекла',
    'Фон стеклянных карточек',
    derived: true,
  ),
  _FieldInfo(
    'glassBorder',
    'Контур стекла',
    'Обводка стеклянных карточек',
    derived: true,
  ),
  _FieldInfo(
    'glowFill',
    'Свечение',
    'Мягкая подсветка вокруг акцента',
    derived: true,
  ),
];

class CustomThemeScreen extends StatefulWidget {
  final String themeId;
  const CustomThemeScreen({super.key, required this.themeId});

  @override
  State<CustomThemeScreen> createState() => _CustomThemeScreenState();
}

class _CustomThemeScreenState extends State<CustomThemeScreen> {
  Palette? get _theme {
    for (final p in ThemeService.instance.customPresets) {
      if (p.id == widget.themeId) return p;
    }
    return null;
  }

  Future<void> _pickColor(_FieldInfo field, Color current) async {
    Color picked = current;
    final result = await showModalBottomSheet<Color>(
      context: context,
      isScrollControlled: true,
      backgroundColor: GE.bgDeep,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 14,
            bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: GE.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                field.label,
                style: TextStyle(
                  color: GE.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(field.hint, style: TextStyle(color: GE.sub, fontSize: 12)),
              const SizedBox(height: 18),
              ColorPickerPanel(
                initial: current,
                onChanged: (c) {
                  picked = c;
                  // Живьём, без записи на диск на каждый тик перетаскивания —
                  // весь остальной UI перекрашивается сразу, дисковая запись
                  // случится один раз при закрытии пикера (см. ниже).
                  ThemeService.instance.previewCustomField(
                    widget.themeId,
                    field.key,
                    c,
                  );
                  if (mounted) setState(() {});
                },
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: GE.sub,
                        side: BorderSide(color: GE.border),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(GE.radiusMd),
                        ),
                      ),
                      child: const Text('Отмена'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, picked),
                      style: FilledButton.styleFrom(
                        backgroundColor: GE.primary,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(GE.radiusMd),
                        ),
                      ),
                      child: const Text(
                        'Применить',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    // И "Отмена", и "Применить" фиксируют финальный цвет на диск разом —
    // на "Отмена" это откат к исходному (перетаскивание уже подменило живое
    // превью через previewCustomField, но диск ещё не трогали).
    await ThemeService.instance.setCustomField(
      widget.themeId,
      field.key,
      result ?? current,
    );
    if (mounted) setState(() {});
  }

  /// Долгое нажатие на поверхность — взять именно этот цвет из другой своей
  /// темы, не открывая пикер (пипетка «Перенести цвет поверхности»).
  Future<void> _transferSurface(_FieldInfo f) async {
    final sourceId = await pickSourceCustomTheme(
      context,
      excludeId: widget.themeId,
    );
    if (sourceId == null) return;
    await ThemeService.instance.transferSurfaceTo(
      fromId: sourceId,
      toId: widget.themeId,
      field: f.key,
    );
    if (mounted) setState(() {});
  }

  Future<void> _finish() async {
    final ctrl = TextEditingController(text: _theme?.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Название темы', style: TextStyle(color: GE.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 40,
          style: TextStyle(color: GE.text),
          decoration: InputDecoration(hintText: 'Например, «Мой закат»'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(
              'Готово',
              style: TextStyle(color: GE.primary, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    if (name == null) return; // отменили — тема остаётся черновиком, это ок
    await ThemeService.instance.renameCustomTheme(widget.themeId, name);
    if (mounted) Navigator.of(context).pop();
  }

  Widget _preview(Palette p) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: p.primary,
                child: Icon(Icons.person, size: 15, color: p.bg),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Пример чата',
                  style: TextStyle(
                    color: p.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: p.green,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 220),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Как тебе новая тема?',
                style: TextStyle(color: p.text, fontSize: 13),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 220),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [p.primary, p.primary2]),
                borderRadius: BorderRadius.circular(12),
              ),
              child: EmojiText(
                'Огонь 🔥',
                style: TextStyle(color: p.bg, fontSize: 13),
                allowFormatting: false,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 14, color: p.yellow),
              const SizedBox(width: 4),
              Text(
                'предупреждение',
                style: TextStyle(color: p.sub, fontSize: 11),
              ),
              const SizedBox(width: 14),
              Icon(Icons.error_outline, size: 14, color: p.red),
              const SizedBox(width: 4),
              Text('ошибка', style: TextStyle(color: p.sub, fontSize: 11)),
              const SizedBox(width: 14),
              Icon(Icons.info_outline, size: 14, color: p.blue),
              const SizedBox(width: 4),
              Text('инфо', style: TextStyle(color: p.sub, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  /// Предупреждение о низком контрасте текста на фоне — порог 3.0 (мягче
  /// строгого WCAG AA 4.5, чтобы не ругаться на нормальные, но не идеальные
  /// сочетания). Цвета юзера не трогаем, только подсказываем.
  Widget _contrastWarning(Palette p) {
    final ratio = _contrastRatio(p.text, p.bg);
    if (ratio >= 3.0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: GE.yellow.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(GE.radiusSm),
          border: Border.all(color: GE.yellow.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(Icons.visibility_off_outlined, color: GE.yellow, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Текст плохо читается на фоне — слишком низкий контраст. '
                'Сделай текст светлее или фон темнее.',
                style: TextStyle(color: GE.text, fontSize: 11.5, height: 1.3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(Palette p, _FieldInfo f) {
    final color = p[f.key];
    return PressScale(
      onTap: () => _pickColor(f, color),
      onLongPress: () => _transferSurface(f),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: GE.border),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.label,
                    style: TextStyle(
                      color: GE.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    f.hint,
                    style: TextStyle(color: GE.sub, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 4, top: 4),
    child: Text(
      text,
      style: TextStyle(
        color: GE.muted,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final p = _theme;
    if (p == null) {
      // Тему удалили (напр. лимит/гонка) — тихо выходим.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return const SizedBox.shrink();
    }
    return Scaffold(
      backgroundColor: p.bg,
      appBar: GlassAppBar(
        showBack: true,
        titleText: p.name.isEmpty ? 'Своя тема' : p.name,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
          children: [
            _preview(p),
            _contrastWarning(p),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Долгое нажатие на цвет — взять его из другой своей темы',
                style: TextStyle(color: GE.muted, fontSize: 10.5),
              ),
            ),
            const SizedBox(height: 6),
            _sectionLabel('ОСНОВНЫЕ'),
            for (final f in _fields.where((f) => !f.derived)) _row(p, f),
            const SizedBox(height: 10),
            _sectionLabel('ПОВЕРХНОСТИ'),
            for (final f in _fields.where((f) => f.derived)) _row(p, f),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _finish,
        backgroundColor: GE.primary,
        label: const Text('Далее'),
        icon: const Icon(Icons.check),
      ),
    );
  }
}
