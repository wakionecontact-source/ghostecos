// GhostAvatar — единый виджет аватарки с диск-кэшем (AvatarCache), везде в
// приложении вместо голого NetworkImage/цветного кружка с инициалом.
// Blur-up (как в Telegram): пока грузится полный размер, мгновенно
// показываем крошечный заблюренный thumbnail (сервер генерирует его вместе
// с оригиналом — {id}_{ver}_thumb.jpg рядом с {id}_{ver}.jpg), потом
// плавный crossfade на full-size. Fallback (нет avatar_url вообще, или
// ничего не скачалось/недоступно) — градиентный кружок с первой буквой
// имени, как было раньше везде.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../services/auth_service.dart';
import '../core/local/app_logger.dart';
import '../theme.dart';

class AvatarCache {
  AvatarCache._();
  static final AvatarCache instance = AvatarCache._();

  final Map<String, Uint8List> _mem = {};
  Directory? _dir;

  /// Notifies mounted avatars when a local image is promoted into memory.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static String? resolveUrl(String? value) {
    final u = value?.trim();
    if (u == null || u.isEmpty) return null;
    if (u.startsWith('http')) return u;
    return u.startsWith('/') ? '${GE.baseUrl}$u' : '${GE.baseUrl}/$u';
  }

  Future<Directory> _dirFor() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/avatar_cache');
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    return d;
  }

  String _fileName(String url) => url.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');

  Future<File> _fileFor(String url) async {
    final d = await _dirFor();
    return File('${d.path}/${_fileName(url)}');
  }

  /// Синхронно — то, что уже в памяти (после первой загрузки в этой сессии).
  Uint8List? getMemSync(String url) => _mem[url];

  /// Диск (переживает перезапуск приложения) — асинхронно, но без сети.
  Future<Uint8List?> getFromDisk(String url) async {
    final mem = _mem[url];
    if (mem != null) return mem;
    try {
      final f = await _fileFor(url);
      if (await f.exists()) {
        final bytes = await f.readAsBytes();
        _mem[url] = bytes;
        revision.value++;
        return bytes;
      }
    } catch (_) {}
    return null;
  }

  Future<void> save(String url, Uint8List bytes) async {
    _mem[url] = bytes;
    revision.value++;
    try {
      final f = await _fileFor(url);
      await f.writeAsBytes(bytes);
    } catch (_) {}
  }

  /// Warms the in-memory cache from disk without delaying app startup.
  Future<void> prime(String? avatarUrl) async {
    final url = resolveUrl(avatarUrl);
    if (url == null) return;
    await getFromDisk(url);
  }

  /// Скачать с сети и закэшировать. Бросает при ошибке — вызывающий сам
  /// решает, что показывать (обычно просто игнорирует и остаётся fallback).
  Future<Uint8List> fetch(String url) async {
    final token = await AuthService.token();
    final headers = <String, String>{
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
    final resp = await http.get(Uri.parse(url), headers: headers);
    if (resp.statusCode != 200) {
      appLog.warn('avatar', 'fetch ${resp.statusCode} ${Uri.parse(url).path}');
      throw Exception('avatar fetch ${resp.statusCode}');
    }
    await save(url, resp.bodyBytes);
    return resp.bodyBytes;
  }
}

class GhostAvatar extends StatefulWidget {
  /// Относительный путь с сервера (например "/media/avatars/xxx.jpg") ИЛИ
  /// уже полный URL — оба варианта ок, короткий домаппится на GE.baseUrl.
  final String? avatarUrl;
  final String fallbackText;
  final double size;
  final List<Color>? fallbackColors;
  final IconData? fallbackIcon;

  const GhostAvatar({
    super.key,
    required this.avatarUrl,
    required this.fallbackText,
    this.size = 44,
    this.fallbackColors,
    this.fallbackIcon,
  });

  String? get _fullUrl {
    final u = avatarUrl;
    if (u == null || u.isEmpty) return null;
    if (u.startsWith('http')) return u;
    return u.startsWith('/') ? '${GE.baseUrl}$u' : '${GE.baseUrl}/$u';
  }

  /// Thumb лежит рядом с оригиналом под тем же именем + "_thumb" (см.
  /// upload_avatar в social_router.py) — только для .jpg (все аватарки
  /// сервер сохраняет как jpg); старых аватарок без thumb это просто не
  /// коснётся (fetch на несуществующий thumb-URL кидает 404 → тихо
  /// игнорируется, ждём full как раньше).
  String? get _thumbUrl {
    final full = _fullUrl;
    if (full == null || !full.endsWith('.jpg')) return null;
    return '${full.substring(0, full.length - 4)}_thumb.jpg';
  }

  @override
  State<GhostAvatar> createState() => _GhostAvatarState();
}

class _GhostAvatarState extends State<GhostAvatar> {
  Uint8List? _bytes;
  bool _isThumb = false;
  String? _loadedFor;

  @override
  void initState() {
    super.initState();
    AvatarCache.instance.revision.addListener(_onCacheRevision);
    _syncThenLoad();
  }

  void _onCacheRevision() {
    if (!mounted) return;
    final url = widget._fullUrl;
    if (url == null || _loadedFor != url) return;
    final full = AvatarCache.instance.getMemSync(url);
    final thumbUrl = widget._thumbUrl;
    final thumb = thumbUrl == null
        ? null
        : AvatarCache.instance.getMemSync(thumbUrl);
    if (full != null &&
        (_bytes == null || _isThumb || !identical(_bytes, full))) {
      setState(() {
        _bytes = full;
        _isThumb = false;
      });
    } else if (_bytes == null && thumb != null) {
      setState(() {
        _bytes = thumb;
        _isThumb = true;
      });
    }
  }

  @override
  void didUpdateWidget(covariant GhostAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget._fullUrl != widget._fullUrl) {
      _bytes = null;
      _isThumb = false;
      _syncThenLoad();
    }
  }

  void _syncThenLoad() {
    final url = widget._fullUrl;
    if (url == null) return;
    _loadedFor = url;
    final memFull = AvatarCache.instance.getMemSync(url);
    if (memFull != null) {
      _bytes = memFull;
      _isThumb = false;
    } else {
      final thumbUrl = widget._thumbUrl;
      final memThumb = thumbUrl != null
          ? AvatarCache.instance.getMemSync(thumbUrl)
          : null;
      _bytes = memThumb;
      _isThumb = memThumb != null;
    }
    _load(url);
  }

  @override
  void dispose() {
    AvatarCache.instance.revision.removeListener(_onCacheRevision);
    super.dispose();
  }

  Future<void> _load(String url, {int attempt = 0}) async {
    // Диск: full — сразу заменяет thumb/пустоту, лучший вариант из доступных.
    if (_bytes == null || _isThumb) {
      final fullDisk = await AvatarCache.instance.getFromDisk(url);
      if (fullDisk != null && mounted && _loadedFor == url) {
        setState(() {
          _bytes = fullDisk;
          _isThumb = false;
        });
      }
    }
    // Если full нигде нет (ни в памяти, ни на диске) — успеваем показать
    // хотя бы blur-up thumbnail, пока летит запрос за full-size.
    if (_bytes == null) {
      final thumbUrl = widget._thumbUrl;
      if (thumbUrl != null) {
        final thumbDisk = await AvatarCache.instance.getFromDisk(thumbUrl);
        if (thumbDisk != null &&
            mounted &&
            _loadedFor == url &&
            _bytes == null) {
          setState(() {
            _bytes = thumbDisk;
            _isThumb = true;
          });
        } else {
          try {
            final freshThumb = await AvatarCache.instance.fetch(thumbUrl);
            if (mounted && _loadedFor == url && _bytes == null) {
              setState(() {
                _bytes = freshThumb;
                _isThumb = true;
              });
            }
          } catch (_) {
            // Старая аватарка без thumb (загружена до этой фичи) — норм,
            // просто ждём full как раньше.
          }
        }
      }
    }
    try {
      final fresh = await AvatarCache.instance.fetch(url);
      if (mounted && _loadedFor == url) {
        setState(() {
          _bytes = fresh;
          _isThumb = false;
        });
      }
    } catch (_) {
      // Сетевая ошибка (не 404 — сервер прислал бы avatar_url:null и мы бы
      // сюда не попали) — один повтор через паузу вместо того, чтобы молча
      // сдаться навсегда до следующего пересоздания виджета.
      if (attempt < 1 && mounted) {
        await Future.delayed(const Duration(seconds: 3));
        if (mounted && _loadedFor == url) _load(url, attempt: attempt + 1);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    Widget content;
    if (bytes == null) {
      content = KeyedSubtree(
        key: const ValueKey('fallback'),
        child: Center(
          child: widget.fallbackIcon != null
              ? Icon(
                  widget.fallbackIcon,
                  color: Colors.white,
                  size: widget.size * 0.42,
                )
              : Text(
                  widget.fallbackText.isNotEmpty
                      ? widget.fallbackText[0].toUpperCase()
                      : '?',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: widget.size * 0.4,
                  ),
                ),
        ),
      );
    } else {
      final img = Image.memory(
        bytes,
        key: ValueKey(_isThumb ? 'thumb' : 'full'),
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
      content = _isThumb
          ? ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
              child: img,
            )
          : img;
    }
    final radius = BorderRadius.circular(ghostAvatarCornerRadius(widget.size));
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          colors: widget.fallbackColors ?? [GE.primary2, GE.primary],
        ),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: content,
        ),
      ),
    );
  }
}

/// The global corner setting controls avatars too: 0 is square and 1 is a
/// circle, with the normal app value producing a rounded square.
double ghostAvatarCornerRadius(double size) =>
    (size * 0.5 * GE.cornerFactor).clamp(0.0, size * 0.5).toDouble();
