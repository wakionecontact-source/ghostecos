// GhostGallery — каталог расширений GhostUI.
//
// Каталог загружается с бэкенда GhostEcos, аватарки и описания приходят
// вместе с карточками. Скачивание и установка — на странице расширения.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../mesh_background.dart';
import '../models/gallery_extension.dart';
import '../services/api_client.dart';
import '../theme.dart';
import '../ui/ui_runtime.dart';
import '../widgets/gallery_avatar.dart';
import '../widgets/glass.dart';
import 'extension_detail_screen.dart';

class GhostGalleryScreen extends StatefulWidget {
  const GhostGalleryScreen({super.key});

  @override
  State<GhostGalleryScreen> createState() => _GhostGalleryScreenState();
}

class _GhostGalleryScreenState extends State<GhostGalleryScreen> {
  List<GalleryExtension> _items = const <GalleryExtension>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final items = await ApiClient().galleryExtensions();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить каталог: $error';
      });
    }
  }

  Future<void> _openDetail(GalleryExtension extension) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExtensionDetailScreen(extension: extension),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(
          showBack: true,
          titleText: 'GhostGallery',
          actions: [
            IconButton(
              onPressed: _loading ? null : () => _load(silent: true),
              icon: Icon(CupertinoIcons.refresh, color: GE.sub, size: 20),
              tooltip: 'Обновить каталог',
            ),
          ],
        ),
        body: ValueListenableBuilder<int>(
          valueListenable: UiRuntime.instance.revision,
          builder: (context, _, _) {
            return RefreshIndicator(
              onRefresh: () => _load(silent: true),
              color: GE.primary,
              backgroundColor: GE.surfaceElevated,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                children: [
                  _heroCard(),
                  const SizedBox(height: 22),
                  _sectionTitle('Каталог расширений'),
                  if (_loading && _items.isEmpty)
                    _loadingCard()
                  else if (_error != null && _items.isEmpty)
                    _errorCard()
                  else if (_items.isEmpty)
                    _emptyCard()
                  else ...[
                    for (var i = 0; i < _items.length; i++) ...[
                      if (i > 0) const SizedBox(height: 10),
                      _extensionCard(_items[i]),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      _errorCard(),
                    ],
                  ],
                  const SizedBox(height: 22),
                  _sectionTitle('Как это работает'),
                  _infoCard(),
                  const SizedBox(height: 16),
                  _rulesNote(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _heroCard() {
    final runtime = UiRuntime.instance;
    final current = runtime.currentExtension;
    return GlassCard(
      isListSection: true,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: GE.accentSoft,
              borderRadius: BorderRadius.circular(GE.radiusMd),
            ),
            child: Icon(
              CupertinoIcons.square_grid_2x2,
              color: GE.primary,
              size: 27,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Оформление GhostChat',
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Скачивай дизайны из каталога и переключайся между ними. '
                  'Каждый конфиг проверяется подписью GhostEcos.',
                  style: TextStyle(
                    color: GE.sub,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _pill(current.name, accent: true),
                    _pill(
                      _items.isEmpty
                          ? 'каталог загружается'
                          : '${_items.length} расширения',
                      accent: false,
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

  Widget _extensionCard(GalleryExtension extension) {
    final runtime = UiRuntime.instance;
    final selected = runtime.currentId.value == extension.id;
    final installed = runtime.isInstalled(extension.id);
    final author = extension.author.isEmpty ? 'GhostEcos' : extension.author;
    return GlassCard(
      isListSection: true,
      padding: EdgeInsets.zero,
      onTap: () => _openDetail(extension),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GalleryAvatar(url: extension.avatarUrl, size: 56),
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
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (extension.isDefault) ...[
                        const SizedBox(width: 8),
                        _pill('ПО УМОЛЧАНИЮ', accent: true),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$author · v${extension.version}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: GE.muted, fontSize: 11),
                  ),
                  if (extension.description.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      extension.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: GE.sub,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (selected)
                        _pill('ВЫБРАНО', accent: true)
                      else if (installed)
                        _pill('УСТАНОВЛЕНО', accent: false)
                      else
                        _pill('СКАЧАТЬ', accent: false),
                      Text(
                        extension.sizeLabel,
                        style: TextStyle(color: GE.muted, fontSize: 10.5),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Icon(
                CupertinoIcons.chevron_forward,
                size: 16,
                color: GE.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _loadingCard() => GlassCard(
    isListSection: true,
    padding: const EdgeInsets.symmetric(vertical: 34),
    child: Column(
      children: [
        SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: GE.primary,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Загружаем каталог GhostGallery…',
          style: TextStyle(color: GE.sub, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _errorCard() => GlassCard(
    isListSection: true,
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              CupertinoIcons.exclamationmark_triangle_fill,
              color: GE.yellow,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Каталог недоступен',
                style: TextStyle(
                  color: GE.text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _error ?? 'Неизвестная ошибка',
          style: TextStyle(color: GE.sub, fontSize: 11.5, height: 1.4),
        ),
        const SizedBox(height: 12),
        GlassButton(
          label: 'Повторить',
          icon: CupertinoIcons.refresh,
          onTap: _load,
        ),
      ],
    ),
  );

  Widget _emptyCard() => GlassCard(
    isListSection: true,
    padding: const EdgeInsets.all(16),
    child: Text(
      'В каталоге пока нет расширений.',
      style: TextStyle(color: GE.sub, fontSize: 12),
    ),
  );

  Widget _infoCard() => GlassCard(
    isListSection: true,
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      children: [
        _InfoRow(
          icon: CupertinoIcons.cloud_download,
          title: 'Скачивание из каталога',
          subtitle:
              'Файл расширения приходит с сервера GhostGallery. Без входа '
              'в GhostEcos скачивание недоступно.',
        ),
        _InfoRow(
          icon: CupertinoIcons.checkmark_shield,
          title: 'Проверка подписи',
          subtitle:
              'Перед установкой приложение проверяет SHA-256 и подпись '
              'манифеста RSA-PSS SHA-256.',
        ),
        _InfoRow(
          icon: CupertinoIcons.arrow_uturn_left,
          title: 'Откат при ошибке',
          subtitle:
              'Если конфиг не прошёл валидацию, применяется безопасный '
              'базовый дизайн, а ошибка показывается в каталоге.',
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
          'Сейчас в каталоге только официальные расширения GhostEcos. '
          'Публикация авторов, рейтинги и комментарии появятся позже.',
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
      color: accent ? GE.accentSoft : GE.surfaceElevated,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: accent ? GE.primary : GE.sub,
        fontSize: 9.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
      ),
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: GE.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: GE.sub,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
