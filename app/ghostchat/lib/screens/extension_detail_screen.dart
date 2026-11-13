// Страница расширения GhostGallery: описание, статус и установка.
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../mesh_background.dart';
import '../models/gallery_extension.dart';
import '../services/api_client.dart';
import '../services/gallery_signature.dart';
import '../theme.dart';
import '../ui/ui_runtime.dart';
import '../widgets/gallery_avatar.dart';
import '../widgets/glass.dart';
import '../widgets/toast_overlay.dart';

class ExtensionDetailScreen extends StatefulWidget {
  const ExtensionDetailScreen({super.key, required this.extension});

  final GalleryExtension extension;

  @override
  State<ExtensionDetailScreen> createState() => _ExtensionDetailScreenState();
}

class _ExtensionDetailScreenState extends State<ExtensionDetailScreen> {
  late GalleryExtension _extension = widget.extension;
  bool _loadingDetail = true;
  bool _busy = false;
  String? _detailError;
  double? _progress;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() {
      _loadingDetail = true;
      _detailError = null;
    });
    try {
      final full = await ApiClient().galleryExtension(widget.extension.id);
      if (!mounted) return;
      setState(() {
        _extension = full;
        _loadingDetail = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingDetail = false;
        _detailError = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingDetail = false;
        _detailError = 'Не удалось загрузить карточку: $error';
      });
    }
  }

  Future<void> _apply() async {
    if (_busy) return;
    final runtime = UiRuntime.instance;
    final id = _extension.id;
    if (runtime.currentId.value == id && runtime.isInstalled(id)) return;

    setState(() {
      _busy = true;
      _progress = null;
    });

    try {
      if (runtime.isInstalled(id)) {
        await runtime.setExtension(id);
        final errors = runtime.lastErrors.value;
        if (errors.isNotEmpty) {
          throw StateError(errors.first);
        }
      } else {
        final full = _extension.hasSignature
            ? _extension
            : await ApiClient().galleryExtension(id);
        if (!full.hasSignature) {
          throw StateError('Сервер не вернул подпись расширения');
        }

        final bytes = await ApiClient().galleryDownload(
          id,
          onProgress: (received, total) {
            if (!mounted) return;
            setState(() {
              _progress = total > 0 ? received / total : null;
            });
          },
        );

        final expected = (full.manifest['sha256'] ?? '').toString();
        final actual = GallerySignature.sha256Hex(bytes);
        if (expected.isEmpty ||
            actual.toLowerCase() != expected.toLowerCase()) {
          throw StateError('SHA-256 файла не совпал с манифестом');
        }

        final publicKey = await rootBundle.loadString(
          'assets/keys/gallery_pub.pem',
        );
        if (!GallerySignature.verifyManifest(
          manifest: full.manifest,
          signatureBase64: full.signature,
          publicKeyPem: publicKey,
        )) {
          throw StateError('Подпись манифеста недействительна');
        }

        final installed = await runtime.installAndApply(
          id,
          utf8.decode(bytes),
          name: full.name,
          version: full.version,
          author: full.author,
          description: full.description,
          tag: full.isDefault ? 'DEFAULT' : null,
        );
        if (!installed) {
          final errors = runtime.lastErrors.value;
          throw StateError(
            errors.isEmpty ? 'Конфиг не прошёл проверку' : errors.first,
          );
        }
        if (mounted) {
          setState(() => _extension = full);
        }
      }

      if (!mounted) return;
      toast.show('Дизайн «${_extension.name}» применён');
    } on ApiException catch (error) {
      if (mounted) toast.show(error.message);
    } catch (error) {
      if (mounted) toast.show('Не удалось установить: $error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(
          showBack: true,
          titleText: 'Расширение',
          actions: [
            if (_loadingDetail)
              const Padding(
                padding: EdgeInsets.only(right: 16),
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ),
        body: ValueListenableBuilder<int>(
          valueListenable: UiRuntime.instance.revision,
          builder: (context, _, _) {
            final runtime = UiRuntime.instance;
            final selected = runtime.currentId.value == _extension.id;
            final installed = runtime.isInstalled(_extension.id);
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                _headerCard(selected: selected, installed: installed),
                const SizedBox(height: 18),
                _sectionTitle('О расширении'),
                GlassCard(
                  isListSection: true,
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    _extension.description.isEmpty
                        ? 'Автор не добавил описание.'
                        : _extension.description,
                    style: TextStyle(
                      color: _extension.description.isEmpty ? GE.muted : GE.sub,
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                _sectionTitle('Безопасность'),
                _securityCard(),
                if (_detailError != null) ...[
                  const SizedBox(height: 14),
                  _detailErrorCard(),
                ],
                const SizedBox(height: 22),
                if (_progress != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: _progress,
                      minHeight: 5,
                      backgroundColor: GE.surfaceElevated,
                      color: GE.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Скачивание… ${(_progress! * 100).round()}%',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: GE.sub, fontSize: 11),
                  ),
                  const SizedBox(height: 12),
                ],
                GlassButton(
                  label: _actionLabel(selected: selected, installed: installed),
                  icon: selected
                      ? CupertinoIcons.checkmark_seal_fill
                      : (installed
                            ? CupertinoIcons.checkmark_circle
                            : CupertinoIcons.cloud_download),
                  primary: !selected,
                  loading: _busy,
                  fullWidth: true,
                  onTap: selected || _busy ? null : _apply,
                ),
                const SizedBox(height: 10),
                Text(
                  selected
                      ? 'Этот дизайн уже применён.'
                      : installed
                      ? 'Расширение уже скачано — можно применить без загрузки.'
                      : 'Для скачивания нужен вход в GhostEcos.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GE.muted, fontSize: 10.5),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _headerCard({required bool selected, required bool installed}) {
    final author = _extension.author.isEmpty ? 'GhostEcos' : _extension.author;
    return GlassCard(
      isListSection: true,
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          GalleryAvatar(url: _extension.avatarUrl, size: 88),
          const SizedBox(height: 14),
          Text(
            _extension.name,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: GE.text,
              fontSize: 21,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '$author · v${_extension.version}',
            textAlign: TextAlign.center,
            style: TextStyle(color: GE.sub, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              if (_extension.isDefault) _pill('ПО УМОЛЧАНИЮ', accent: true),
              if (selected)
                _pill('ВЫБРАНО', accent: true)
              else if (installed)
                _pill('УСТАНОВЛЕНО', accent: false),
              _pill(_extension.sizeLabel, accent: false),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _stat('Версия', _extension.version)),
              const SizedBox(width: 8),
              Expanded(child: _stat('Размер', _extension.sizeLabel)),
              const SizedBox(width: 8),
              Expanded(child: _stat('ID', _extension.id)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    decoration: BoxDecoration(
      color: GE.surfaceElevated,
      borderRadius: BorderRadius.circular(GE.radiusSm),
    ),
    child: Column(
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            color: GE.muted,
            fontSize: 8.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: GE.text,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  Widget _securityCard() {
    final sha = (_extension.manifest['sha256'] ?? '').toString();
    final shortSha = sha.length > 24
        ? '${sha.substring(0, 12)}…${sha.substring(sha.length - 8)}'
        : sha;
    return GlassCard(
      isListSection: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          _SecurityRow(
            icon: CupertinoIcons.doc_text,
            title: 'Формат GhostUI JSON',
            subtitle:
                'Конфиг описывает цвета, радиусы и элементы интерфейса. '
                'Код на устройстве не исполняется.',
          ),
          _SecurityRow(
            icon: CupertinoIcons.checkmark_shield,
            title: 'Подпись RSA-PSS SHA-256',
            subtitle: sha.isEmpty
                ? 'Манифест проверяется перед установкой.'
                : 'SHA-256 манифеста: $shortSha',
          ),
        ],
      ),
    );
  }

  Widget _detailErrorCard() => GlassCard(
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
              size: 17,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Карточка не загрузилась',
                style: TextStyle(
                  color: GE.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Text(
          _detailError ?? '',
          style: TextStyle(color: GE.sub, fontSize: 11.5, height: 1.4),
        ),
        const SizedBox(height: 10),
        GlassButton(
          label: 'Повторить',
          icon: CupertinoIcons.refresh,
          onTap: _loadDetail,
        ),
      ],
    ),
  );

  String _actionLabel({required bool selected, required bool installed}) {
    if (selected) return 'Уже применено';
    if (installed) return 'Применить';
    return 'Скачать и применить';
  }

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

class _SecurityRow extends StatelessWidget {
  const _SecurityRow({
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
