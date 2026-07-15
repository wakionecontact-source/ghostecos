// Редактор своей темы — правка живьём (весь остальной UI за этим экраном
// уже перекрашен в редактируемую тему, см. ThemeService.createDraftCustomTheme/
// openCustomThemeForEdit). Свернуть экран (кнопка назад) не спрашивает
// "сохранить?" — черновик уже сохранён на каждую правку, "Далее" только
// просит имя и явно завершает тему.
import 'package:flutter/material.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../services/theme_service.dart';
import '../widgets/glass.dart';
import '../widgets/color_picker_panel.dart';

class CustomThemeScreen extends StatefulWidget {
  final String themeId;
  const CustomThemeScreen({super.key, required this.themeId});

  @override
  State<CustomThemeScreen> createState() => _CustomThemeScreenState();
}

class _CustomThemeScreenState extends State<CustomThemeScreen> {
  static const _roleLabels = {
    'bg': 'Фон',
    'primary': 'Акцент',
    'primary2': 'Акцент 2',
    'text': 'Текст',
    'green': 'Успех',
    'yellow': 'Предупреждение',
    'red': 'Ошибка',
    'blue': 'Инфо',
  };
  static const _derivedLabels = {
    'bgDeep': 'Фон (глубокий)',
    'surface': 'Поверхность карточек',
    'border': 'Разделитель',
    'borderStrong': 'Разделитель (акцент)',
    'sub': 'Текст (вторичный)',
    'muted': 'Текст (приглушённый)',
    'glassFill': 'Заливка стекла',
    'glassBorder': 'Контур стекла',
    'glowFill': 'Свечение',
  };

  Palette? get _theme {
    for (final p in ThemeService.instance.customPresets) {
      if (p.id == widget.themeId) return p;
    }
    return null;
  }

  Future<void> _pickColor(String field, Color current) async {
    Color picked = current;
    final result = await showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Цвет', style: TextStyle(color: GE.text, fontSize: 16)),
        content: SingleChildScrollView(
          child: ColorPickerPanel(
            initial: current,
            onChanged: (c) => picked = c,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, picked),
            child: Text('Выбрать',
                style: TextStyle(color: GE.primary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (result == null) return;
    await ThemeService.instance.setCustomField(widget.themeId, field, result);
    if (mounted) setState(() {});
  }

  Future<void> _toggleSmartPaint(bool v) async {
    await ThemeService.instance.setCustomSmartPaint(widget.themeId, v);
    if (mounted) setState(() {});
  }

  Future<void> _toggleDetached(String field, bool detached) async {
    await ThemeService.instance.setFieldDetached(widget.themeId, field, detached);
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
            child: Text('Готово',
                style: TextStyle(color: GE.primary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (name == null) return; // отменили — тема остаётся черновиком, это ок
    await ThemeService.instance.renameCustomTheme(widget.themeId, name);
    if (mounted) Navigator.of(context).pop();
  }

  Widget _row(String field, String label, Color color, {bool derived = false}) {
    final p = _theme;
    final detached = derived && p != null && p.detachedFields.contains(field);
    final showToggle = derived && (p?.smartPaint ?? false);
    return InkWell(
      onTap: () => _pickColor(field, color),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: GE.border),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: TextStyle(color: GE.text, fontSize: 13.5, fontWeight: FontWeight.w600)),
            ),
            if (showToggle) ...[
              Text(detached ? 'своя' : 'авто',
                  style: TextStyle(color: GE.sub, fontSize: 11)),
              const SizedBox(width: 8),
              GhostSwitch(
                value: detached,
                activeColor: GE.primary,
                onChanged: (v) => _toggleDetached(field, v),
              ),
            ],
          ],
        ),
      ),
    );
  }

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
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(
          showBack: true,
          titleText: p.name.isEmpty ? 'Своя тема' : p.name,
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            children: [
              GlassCard(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome_outlined, color: GE.primary, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Умная краска',
                              style: TextStyle(
                                  color: GE.text, fontSize: 13, fontWeight: FontWeight.w600)),
                          Text(
                            'Остальные цвета подстраиваются сами под выбранные ниже',
                            style: TextStyle(color: GE.sub, fontSize: 10.5, height: 1.3),
                          ),
                        ],
                      ),
                    ),
                    GhostSwitch(
                      value: p.smartPaint,
                      activeColor: GE.primary,
                      onChanged: _toggleSmartPaint,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Text('ОСНОВНЫЕ',
                    style: TextStyle(
                        color: GE.muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
              ),
              for (final f in _roleLabels.keys) _row(f, _roleLabels[f]!, p[f]),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Text('ПОВЕРХНОСТИ',
                    style: TextStyle(
                        color: GE.muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
              ),
              for (final f in _derivedLabels.keys)
                _row(f, _derivedLabels[f]!, p[f], derived: true),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _finish,
          backgroundColor: GE.primary,
          label: const Text('Далее'),
          icon: const Icon(Icons.check),
        ),
      ),
    );
  }
}
