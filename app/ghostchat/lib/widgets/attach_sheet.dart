// Telegram-стиль меню скрепки: bottom-sheet с живым гридом галереи (превью
// фото/видео с устройства, мультивыбор) + ряд цветных шорткатов снизу.
//
// Защищённо: если нет доступа к галерее (permission denied / недоступно) —
// показываем кнопку «Разрешить доступ», шорткаты работают всегда. Грид НАДО
// проверить на устройстве (разрешения READ_MEDIA_* + рендер превью).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import '../theme.dart';
import '../services/permissions_service.dart';
import 'video_player_viewer.dart';
import 'skeleton.dart';

/// Один выбранный элемент галереи, разрешённый в файл.
class AttachItem {
  final File file;
  final bool isVideo;
  AttachItem(this.file, this.isVideo);
}

class AttachSheet extends StatefulWidget {
  /// Отправить выбранные из грида элементы (фото/видео).
  final Future<void> Function(List<AttachItem> items) onPickedSend;
  final VoidCallback onGallery; // полная системная галерея
  final VoidCallback onFile; // системный file picker
  final VoidCallback onCamera; // камера
  final VoidCallback onGeo; // геопозиция (заглушка пока)
  final VoidCallback onWallet; // кошелёк (заглушка до GhostBank)
  /// Режим выбора одного изображения без отправки в чат (например, для обоев).
  final bool selectionOnly;
  final int maxSelectionCount;
  final Future<void> Function(File file)? onPickedSelect;
  const AttachSheet({
    super.key,
    required this.onPickedSend,
    required this.onGallery,
    required this.onFile,
    required this.onCamera,
    required this.onGeo,
    required this.onWallet,
    this.selectionOnly = false,
    this.maxSelectionCount = 10,
    this.onPickedSelect,
  });

  @override
  State<AttachSheet> createState() => _AttachSheetState();
}

class _AttachSheetState extends State<AttachSheet> {
  List<AssetEntity> _assets = [];
  final Set<String> _selected = {}; // id выбранных
  final Map<String, Uint8List?> _thumbCache =
      {}; // превью по id (без перезагрузки)
  bool _loading = true;
  bool _denied = false;
  bool _sending = false;
  final bool _showExperimentalAttachSources = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _auditGalleryUsage() async {
    try {
      await PermissionUsageAudit.instance.recordCurrentStatus(
        Permission.photos,
        context: 'attachment_gallery',
      );
      await PermissionUsageAudit.instance.recordCurrentStatus(
        Permission.videos,
        context: 'attachment_gallery',
      );
    } catch (_) {
      // Аудит не должен ломать открытие скрепки.
    }
  }

  Future<void> _load() async {
    try {
      final ps = await PhotoManager.requestPermissionExtend();
      await _auditGalleryUsage();
      if (!ps.hasAccess) {
        if (mounted)
          setState(() {
            _denied = true;
            _loading = false;
          });
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
        type: widget.selectionOnly ? RequestType.image : RequestType.common,
        // фото + видео в обычном режиме; только фото — для выбора обоев
        onlyAll: true,
        // Новые СВЕРХУ + ВИДЕО тоже (дефолтный videoOption отбрасывает видео с
        // null-длительностью — allowNullable их возвращает). RequestType.common
        // = фото+видео.
        filterOption: FilterOptionGroup(
          imageOption: const FilterOption(),
          videoOption: const FilterOption(
            durationConstraint: DurationConstraint(allowNullable: true),
          ),
          orders: [
            const OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );
      if (albums.isEmpty) {
        if (mounted)
          setState(() {
            _assets = [];
            _loading = false;
          });
        return;
      }
      final recent = await albums.first.getAssetListPaged(page: 0, size: 60);
      if (mounted)
        setState(() {
          _assets = recent;
          _loading = false;
        });
    } catch (_) {
      await _auditGalleryUsage();
      if (mounted)
        setState(() {
          _denied = true;
          _loading = false;
        });
    }
  }

  void _toggle(AssetEntity a) {
    HapticFeedback.selectionClick();
    if (!_selected.contains(a.id) &&
        !widget.selectionOnly &&
        _selected.length >= widget.maxSelectionCount) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            'За одну отправку можно выбрать не более ${widget.maxSelectionCount} вложений',
          ),
        ),
      );
      return;
    }
    setState(() {
      if (widget.selectionOnly) _selected.clear();
      if (_selected.contains(a.id)) {
        _selected.remove(a.id);
      } else {
        _selected.add(a.id);
      }
    });
  }

  // Полноэкранный просмотр: фото открывается как изображение, видео — во
  // встроенном плеере. Выбор делается кружком в гриде.
  Future<void> _openPreview(AssetEntity a) async {
    if (a.type == AssetType.video) {
      final file = await a.file;
      if (file == null || !mounted) return;
      Navigator.of(context).push(
        PageRouteBuilder<void>(
          opaque: false,
          barrierColor: Colors.black,
          pageBuilder: (_, _, _) => GhostVideoViewer(path: file.path),
        ),
      );
      return;
    }
    final data = await a.thumbnailDataWithSize(const ThumbnailSize(1080, 1080));
    if (data == null || !mounted) return;
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (ctx, _, _) => GestureDetector(
          onTap: () => Navigator.of(ctx).maybePop(),
          child: Container(
            color: Colors.black,
            alignment: Alignment.center,
            child: Stack(
              alignment: Alignment.center,
              children: [
                InteractiveViewer(
                  child: Image.memory(data, fit: BoxFit.contain),
                ),
                if (a.type == AssetType.video)
                  const Icon(
                    CupertinoIcons.play_circle_fill,
                    color: Colors.white70,
                    size: 64,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _send() async {
    if (_selected.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final picked = _assets.where((a) => _selected.contains(a.id)).toList();
      final items = <AttachItem>[];
      for (final a in picked) {
        try {
          final f = await a.file;
          if (f != null) items.add(AttachItem(f, a.type == AssetType.video));
        } catch (_) {}
      }
      if (mounted) Navigator.of(context).maybePop();
      if (items.isEmpty) return;
      if (widget.selectionOnly && widget.onPickedSelect != null) {
        await widget.onPickedSelect!(items.first.file);
      } else {
        await widget.onPickedSend(items);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    return Container(
      height: h * 0.8,
      decoration: BoxDecoration(
        color: GE.bgDeep,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: GE.glassBorder, width: 1),
      ),
      child: Column(
        children: [
          // Ручка-перетаскивание.
          Container(
            margin: const EdgeInsets.only(top: 8, bottom: 4),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: GE.muted,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(child: _gridArea()),
          if (!widget.selectionOnly) _shortcutRow(),
        ],
      ),
    );
  }

  Widget _gridArea() {
    if (_loading) {
      return const SkeletonGrid(
        count: 12,
        crossAxisCount: 3,
        childAspectRatio: 1,
      );
    }
    if (_denied) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.photo_on_rectangle, color: GE.muted, size: 40),
            const SizedBox(height: 10),
            Text(
              'Нет доступа к галерее',
              style: TextStyle(color: GE.sub, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => PhotoManager.openSetting(),
              child: const Text('Разрешить доступ'),
            ),
          ],
        ),
      );
    }
    return Stack(
      children: [
        GridView.builder(
          padding: const EdgeInsets.all(2),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 2,
            mainAxisSpacing: 2,
          ),
          itemCount: _assets.length + (widget.selectionOnly ? 0 : 1),
          itemBuilder: (_, i) {
            if (!widget.selectionOnly && i == 0) {
              return _InlineCameraCell(
                onTap: () {
                  Navigator.of(context).maybePop();
                  widget.onCamera();
                },
              );
            }
            final assetIndex = widget.selectionOnly ? i : i - 1;
            return _cell(_assets[assetIndex]);
          },
        ),
        // Плавающая камера / кнопка отправки.
        if (!widget.selectionOnly)
          Positioned(
            top: 6,
            right: 6,
            child: PopupMenuButton<String>(
              tooltip: 'Другие источники',
              icon: const Icon(CupertinoIcons.ellipsis, color: Colors.white),
              color: GE.bgDeep,
              onSelected: (value) {
                Navigator.of(context).maybePop();
                switch (value) {
                  case 'gallery':
                    widget.onGallery();
                  case 'file':
                    widget.onFile();
                  case 'camera':
                    widget.onCamera();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'gallery',
                  child: Text('Системная галерея'),
                ),
                PopupMenuItem(value: 'file', child: Text('Файловый проводник')),
                PopupMenuItem(value: 'camera', child: Text('Камера')),
              ],
            ),
          ),
        Positioned(
          right: 16,
          bottom: 16,
          child: _selected.isEmpty
              ? _circleBtn(CupertinoIcons.camera, GE.blue, () {
                  Navigator.of(context).maybePop();
                  widget.onCamera();
                })
              : _circleBtn(
                  _sending
                      ? CupertinoIcons.hourglass
                      : CupertinoIcons.paperplane_fill,
                  GE.primary,
                  _send,
                  badge: _selected.length,
                ),
        ),
      ],
    );
  }

  Widget _cell(AssetEntity a) {
    final sel = _selected.contains(a.id);
    final isVideo = a.type == AssetType.video;
    return GestureDetector(
      onTap: () => _openPreview(a), // тап по фото → полноэкранный просмотр
      child: Stack(
        fit: StackFit.expand,
        children: [
          _thumb(a),
          if (sel) ColoredBox(color: GE.primary.withValues(alpha: 0.30)),
          // Видео остаётся обычной плиткой с кадром, а не иконкой паузы. Слева
          // снизу показываем настоящую продолжительность из медиатеки.
          if (isVideo)
            Positioned(
              left: 6,
              bottom: 6,
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.68),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          CupertinoIcons.video_camera_solid,
                          color: Colors.white,
                          size: 11,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          _formatDuration(a.duration),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          // Кружок-выбор — ТОЛЬКО он переключает выбор (тап по фото = превью).
          Positioned(
            right: 0,
            top: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _toggle(a),
              child: Padding(
                padding: const EdgeInsets.all(5), // увеличить зону тапа
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: sel ? GE.primary : Colors.black26,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: sel
                      ? const Icon(
                          CupertinoIcons.checkmark,
                          color: Colors.white,
                          size: 14,
                        )
                      : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(int seconds) {
    final duration = Duration(seconds: seconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final secs = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$secs' : '$minutes:$secs';
  }

  // Превью элемента: грузим байты один раз, кэшируем по id (на rebuild при
  // выборе не перезагружаем → нет мигания).
  Widget _thumb(AssetEntity a) {
    if (_thumbCache.containsKey(a.id)) {
      final b = _thumbCache[a.id];
      return b != null
          ? Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true)
          : ColoredBox(color: GE.surface);
    }
    return FutureBuilder<Uint8List?>(
      future: a.thumbnailDataWithSize(const ThumbnailSize.square(220)),
      builder: (_, snap) {
        if (snap.connectionState == ConnectionState.done) {
          _thumbCache[a.id] = snap.data;
          final b = snap.data;
          return b != null
              ? Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true)
              : ColoredBox(color: GE.surface);
        }
        return ColoredBox(color: GE.surface);
      },
    );
  }

  Widget _circleBtn(IconData ic, Color c, VoidCallback onTap, {int? badge}) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Icon(ic, color: Colors.white, size: 26),
          ),
          if (badge != null)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
                child: Text(
                  '$badge',
                  style: TextStyle(
                    color: GE.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _shortcutRow() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            // GE.* вместо хардкод-хексов — иначе иконки не меняли тон между
            // темами (были одинаковые на всех 12 пресетах).
            _shortcut(
              CupertinoIcons.photo_on_rectangle,
              'Галерея',
              GE.blue,
              () {
                Navigator.of(context).maybePop();
                widget.onGallery();
              },
            ),
            if (_showExperimentalAttachSources)
              _shortcut(
                Icons.account_balance_wallet_rounded,
                'Кошелёк',
                GE.primary,
                () {
                  Navigator.of(context).maybePop();
                  widget.onWallet();
                },
              ),
            _shortcut(CupertinoIcons.doc, 'Файл', GE.primary2, () {
              Navigator.of(context).maybePop();
              widget.onFile();
            }),
            if (_showExperimentalAttachSources)
              _shortcut(
                CupertinoIcons.location_solid,
                'Геопозиция',
                GE.green,
                () {
                  Navigator.of(context).maybePop();
                  widget.onGeo();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _shortcut(IconData ic, String label, Color c, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: c,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(ic, color: Colors.white, size: 26),
            ),
            const SizedBox(height: 5),
            Text(label, style: TextStyle(color: GE.sub, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _InlineCameraCell extends StatefulWidget {
  final VoidCallback onTap;
  const _InlineCameraCell({required this.onTap});

  @override
  State<_InlineCameraCell> createState() => _InlineCameraCellState();
}

class _InlineCameraCellState extends State<_InlineCameraCell> {
  static String? _lastFramePath;
  static DateTime? _lastFrameAt;
  CameraController? _controller;
  Timer? _frameTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      final camera = cameras.firstWhere(
        (item) => item.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        camera,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      await _refreshLastFrame();
      _frameTimer = Timer.periodic(
        const Duration(minutes: 1),
        (_) => _refreshLastFrame(),
      );
    } catch (_) {
      // The tile remains a camera shortcut if preview permission is delayed.
    }
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _refreshLastFrame() async {
    final controller = _controller;
    final last = _lastFrameAt;
    if (controller == null ||
        !controller.value.isInitialized ||
        controller.value.isTakingPicture ||
        (last != null &&
            DateTime.now().difference(last) < const Duration(minutes: 1))) {
      return;
    }
    try {
      final shot = await controller.takePicture();
      _lastFramePath = shot.path;
      _lastFrameAt = DateTime.now();
      if (mounted) setState(() {});
    } catch (_) {
      // Пока камера занята, старый кадр остаётся валидным placeholder.
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller?.value.isInitialized == true;
    return GestureDetector(
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (ready)
              CameraPreview(controller!)
            else if (_lastFramePath != null)
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
                child: Image.file(
                  File(_lastFramePath!),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => ColoredBox(color: GE.surface),
                ),
              )
            else
              ColoredBox(color: GE.surface),
            if (!ready)
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: ColoredBox(color: GE.primary.withValues(alpha: 0.12)),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.68),
                  ],
                ),
              ),
            ),
            const Center(
              child: Icon(
                CupertinoIcons.camera_fill,
                color: Colors.white,
                size: 30,
              ),
            ),
            const Positioned(
              left: 7,
              bottom: 6,
              child: Text(
                'Камера',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
