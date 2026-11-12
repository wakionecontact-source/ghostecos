// GhostGallery — витрина GhostUI.
//
// MVP: показывает встроенные конфиги-расширения, позволяет переключить
// оформление и увидеть ошибки валидации. Установка сторонних расширений,
// модерация и подписи появятся позже — раздел «Скоро» честно об этом говорит.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../mesh_background.dart';
import '../theme.dart';
import '../ui/ui_runtime.dart';
import '../widgets/glass.dart';
import '../widgets/toast_overlay.dart';

class GhostGalleryScreen extends StatefulWidget {
  const GhostGalleryScreen({super.key});

  @override
  State<GhostGalleryScreen> createState() => _GhostGalleryScreenState();
}

class _GhostGalleryScreenState extends State<GhostGalleryScreen> {
  String? _applyingId;

  Future<void> _select(UiExtensionInfo extension) async {
    if (_applyingId != null) return;
    setState(() => _applyingId = extension.id);
    try {
      await UiRuntime.instance.setExtension(extension.id);
    } finally {
      if (mounted) setState(() => _applyingId = null);
    }
    if (!mounted) return;
    final errors = UiRuntime.instance.lastErrors.value;
    toast.show(
      errors.isEmpty
          ? 'GhostUI: ${UiRuntime.instance.currentExtension.name}'
          : 'Конфиг не загружен: ${errors.first}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: const GlassAppBar(showBack: true, titleText: 'GhostGallery'),
        body: ValueListenableBuilder<int>(
          valueListenable: UiRuntime.instance.revision,
          builder: (context, _, _) {
            final runtime = UiRuntime.instance;
            final errors = runtime.lastErrors.value;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                _heroCard(runtime),
                const SizedBox(height: 22),
                _sectionTitle('Установленные конфиги'),
                GlassCard(
                  isListSection: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < UiRuntime.extensions.length; i++) ...[
                        if (i > 0) const SizedBox(height: 4),
                        _extensionTile(
                          UiRuntime.extensions[i],
                          selected: runtime.currentId.value ==
                              UiRuntime.extensions[i].id,
                        ),
                      ],
                    ],
                  ),
                ),
                if (errors.isNotEmpty) ...[
                  const SizedBox(height: 22),
                  _sectionTitle('Ошибки загрузки'),
                  _errorCard(errors),
                ],
                const SizedBox(height: 22),
                _sectionTitle('Скоро'),
                GlassCard(
                  isListSection: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    children: const [
                      _SoonRow(
                        icon: CupertinoIcons.square_grid_2x2,
                        title: 'Каталог сообщества',
                        subtitle:
                            'Публикация и установка расширений. Нужны '
                            'модерация, подписи и ревью.',
                      ),
                      _SoonRow(
                        icon: CupertinoIcons.doc,
                        title: 'Установка из файла',
                        subtitle:
                            'Импорт .ghui/JSON с проверкой схемы, лимитами '
                            'и откатом.',
                      ),
                      _SoonRow(
                        icon: CupertinoIcons.arrow_2_circlepath,
                        title: 'Обновления и откат',
                        subtitle:
                            'Версии, kill-switch и возврат к рабочему '
                            'оформлению.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                _rulesNote(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _heroCard(UiRuntime runtime) {
    final current = runtime.currentExtension;
    return GlassCard(
      isListSection: true,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: GE.accentSoft,
              borderRadius: BorderRadius.circular(GE.radiusMd),
            ),
            child: Icon(
              CupertinoIcons.square_grid_2x2,
              color: GE.primary,
              size: 26,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'GhostGallery',
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Каталог оформления GhostUI. Конфиг задаёт цвета, размеры '
                  'и расположение элементов.',
                  style: TextStyle(
                    color: GE.sub,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _pill(current.name, accent: true),
                    const SizedBox(width: 8),
                    Text(
                      'v${current.version}',
                      style: TextStyle(color: GE.muted, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _extensionTile(
    UiExtensionInfo extension, {
    required bool selected,
  }) {
    final busy = _applyingId == extension.id;
    return PressScale(
      onTap: _applyingId == null ? () => _select(extension) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? GE.primary.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(GE.radiusMd),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: GE.surfaceElevated,
                borderRadius: BorderRadius.circular(GE.radiusMd),
              ),
              child: Icon(
                selected
                    ? CupertinoIcons.checkmark_seal_fill
                    : CupertinoIcons.paintbrush_fill,
                color: selected ? GE.primary : GE.sub,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          extension.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: GE.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (extension.tag != null) ...[
                        const SizedBox(width: 8),
                        _pill(extension.tag!, accent: false),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${extension.id} · ${extension.author}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: GE.muted, fontSize: 10.5),
                  ),
                  if (extension.description.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      extension.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: GE.sub,
                        fontSize: 11.5,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (busy)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: GE.primary,
                ),
              )
            else
              Icon(
                selected
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.circle,
                color: selected ? GE.primary : GE.muted,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }

  Widget _errorCard(List<String> errors) => GlassCard(
    isListSection: true,
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(CupertinoIcons.exclamationmark_triangle_fill,
                color: GE.red, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Конфиг не прошёл проверку. Применён Ghost Default.',
                style: TextStyle(
                  color: GE.text,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final error in errors)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '• $error',
              style: TextStyle(color: GE.red, fontSize: 11.5, height: 1.35),
            ),
          ),
      ],
    ),
  );

  Widget _rulesNote() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(CupertinoIcons.info_circle, size: 14, color: GE.muted),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          'Каждый элемент реестра обязан иметь конфиг. Радиус задаётся '
          'только глобально, расположение — через layout-свойства. '
          'Сейчас доступны встроенные конфиги; установка расширений — позже.',
          style: TextStyle(color: GE.muted, fontSize: 11, height: 1.4),
        ),
      ),
    ],
  );

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        color: GE.sub,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      ),
    ),
  );

  Widget _pill(String text, {required bool accent}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: accent
          ? GE.primary.withValues(alpha: 0.14)
          : GE.surfaceElevated,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: accent ? GE.primary : GE.sub,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
      ),
    ),
  );
}

class _SoonRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _SoonRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: () => toast.show('Временно недоступно'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: GE.muted),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            color: GE.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: GE.surfaceElevated,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'СКОРО',
                          style: TextStyle(
                            color: GE.muted,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: GE.sub,
                      fontSize: 11,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
