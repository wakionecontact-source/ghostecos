// Telegram-стиль меню скрепки: bottom-sheet с живым гридом галереи (превью
// фото/видео с устройства, мультивыбор) + ряд цветных шорткатов снизу.
//
// Защищённо: если нет доступа к галерее (permission denied / недоступно) —
// показываем кнопку «Разрешить доступ», шорткаты работают всегда. Грид НАДО
// проверить на устройстве (разрешения READ_MEDIA_* + рендер превью).
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import '../theme.dart';

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
  const AttachSheet({
    super.key,
    required this.onPickedSend,
    required this.onGallery,
    required this.onFile,
    required this.onCamera,
    required this.onGeo,
    required this.onWallet,
  });

  @override
  State<AttachSheet> createState() => _AttachSheetState();
}

class _AttachSheetState extends State<AttachSheet> {
  List<AssetEntity> _assets = [];
  final Set<String> _selected = {}; // id выбранных
  final Map<String, Uint8List?> _thumbCache = {}; // превью по id (без перезагрузки)
  bool _loading = true;
  bool _denied = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final ps = await PhotoManager.requestPermissionExtend();
      if (!ps.hasAccess) {
        if (mounted) setState(() { _denied = true; _loading = false; });
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common, // фото + видео
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
        if (mounted) setState(() { _assets = []; _loading = false; });
        return;
      }
      final recent = await albums.first.getAssetListPaged(page: 0, size: 60);
      if (mounted) setState(() { _assets = recent; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _denied = true; _loading = false; });
    }
  }

  void _toggle(AssetEntity a) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selected.contains(a.id)) {
        _selected.remove(a.id);
      } else {
        _selected.add(a.id);
      }
    });
  }

  // Полноэкранный просмотр (крупное превью 1080 — работает и для фото, и для
  // кадра видео). Тап по фону — закрыть. Выбор делается кружком в гриде.
  Future<void> _openPreview(AssetEntity a) async {
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
                  const Icon(Icons.play_circle_fill,
                      color: Colors.white70, size: 64),
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
    final picked = _assets.where((a) => _selected.contains(a.id)).toList();
    final items = <AttachItem>[];
    for (final a in picked) {
      try {
        final f = await a.file;
        if (f != null) items.add(AttachItem(f, a.type == AssetType.video));
      } catch (_) {}
    }
    if (mounted) Navigator.of(context).maybePop();
    if (items.isNotEmpty) await widget.onPickedSend(items);
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
          _shortcutRow(),
        ],
      ),
    );
  }

  Widget _gridArea() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: GE.primary));
    }
    if (_denied) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_library_outlined, color: GE.muted, size: 40),
            const SizedBox(height: 10),
            Text('Нет доступа к галерее',
                style: TextStyle(color: GE.sub, fontSize: 13)),
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
          itemCount: _assets.length,
          itemBuilder: (_, i) => _cell(_assets[i]),
        ),
        // Плавающая камера / кнопка отправки.
        Positioned(
          right: 16,
          bottom: 16,
          child: _selected.isEmpty
              ? _circleBtn(
                  Icons.camera_alt_rounded,
                  GE.blue,
                  () {
                    Navigator.of(context).maybePop();
                    widget.onCamera();
                  },
                )
              : _circleBtn(
                  _sending ? Icons.hourglass_top : Icons.send_rounded,
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
          // HD + play для видео.
          if (isVideo)
            Positioned(
              left: 4,
              bottom: 4,
              child: Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('HD',
                        style: TextStyle(color: Colors.white, fontSize: 9,
                            fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
          if (isVideo)
            const Center(
              child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 28),
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
                      ? const Icon(Icons.check, color: Colors.white, size: 14)
                      : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
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
                child: Text('$badge',
                    style: TextStyle(
                        color: GE.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w800)),
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
            _shortcut(Icons.photo_library_rounded, 'Галерея', GE.blue, () {
              Navigator.of(context).maybePop();
              widget.onGallery();
            }),
            _shortcut(Icons.account_balance_wallet_rounded, 'Кошелёк', GE.primary, () {
              Navigator.of(context).maybePop();
              widget.onWallet();
            }),
            _shortcut(Icons.insert_drive_file_rounded, 'Файл', GE.primary2, () {
              Navigator.of(context).maybePop();
              widget.onFile();
            }),
            _shortcut(Icons.location_on_rounded, 'Геопозиция', GE.green, () {
              Navigator.of(context).maybePop();
              widget.onGeo();
            }),
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
            Text(label,
                style: TextStyle(color: GE.sub, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
