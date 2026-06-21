// FeedScreen — нативная лента, эквивалент веб-/social/.
//
// Полная функциональность:
//   • сортировки: Для вас / Новое / Топ / Подписки / Случайно + фильтр по тегу
//   • карточка поста: аватар, имя/@username, время, (ред.), 18+ бейдж,
//     from-channel бейдж, "это вы" / "Подписаться", контент с linkify,
//     медиа-сетка (1-5+ ячеек), просмотры/репосты, реакции (своя ❤ + ряд),
//     комментарии счётчик, share-меню
//   • NSFW: блюр-оверлей с кнопкой "Показать"
//   • действия: tap ❤, long-press → reaction picker, double-tap → ❤,
//     share/копировать/в браузере/пожаловаться, edit/delete своего, follow
//   • composer: текст + картинка + NSFW чекбокс + опубликовать
//   • pull-to-refresh, infinite scroll
//   • hashtag / @mention навигация (тапнул #foo → setTag('foo') → refresh)

import 'dart:async';
import 'dart:ui' show ImageFilter, FontFeature;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/feed_repo.dart';
import '../widgets/glass.dart';
import 'comments_screen.dart';
import 'profile_screen.dart';

class FeedScreen extends StatefulWidget {
  /// embedded=true → не показываем собственный header (используется внутри SocialPane,
  /// который уже имеет верхний таб-бар «Лента / Миниски / Поиск / Уведомления»).
  final bool embedded;
  const FeedScreen({super.key, this.embedded = false});
  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  static const _sorts = [
    ('foryou', 'Для вас'),
    ('new', 'Новое'),
    ('top', 'Топ'),
    ('following', 'Подписки'),
    ('random', 'Случайно'),
  ];

  final _scroll = ScrollController();
  bool _loadingFirst = true;
  String? _myUsername;
  String? _activeTag;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _init();
  }

  Future<void> _init() async {
    _myUsername = await AuthService.username();
    if (FeedRepo.instance.postsNotifier.value.isEmpty) {
      await FeedRepo.instance.refresh();
    }
    if (mounted) setState(() => _loadingFirst = false);
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
      FeedRepo.instance.loadMore();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _switchSort(String s) async {
    HapticFeedback.selectionClick();
    FeedRepo.instance.setSort(s);
    setState(() => _loadingFirst = true);
    await FeedRepo.instance.refresh();
    if (mounted) setState(() => _loadingFirst = false);
  }

  Future<void> _openTag(String tag) async {
    FeedRepo.instance.setTag(tag);
    FeedRepo.instance.setSort('new');
    setState(() {
      _activeTag = tag;
      _loadingFirst = true;
    });
    await FeedRepo.instance.refresh();
    if (mounted) setState(() => _loadingFirst = false);
  }

  Future<void> _clearTag() async {
    FeedRepo.instance.setTag(null);
    setState(() {
      _activeTag = null;
      _loadingFirst = true;
    });
    await FeedRepo.instance.refresh();
    if (mounted) setState(() => _loadingFirst = false);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (!widget.embedded) _header(),
        _sortBar(),
        if (_activeTag != null) _tagBar(),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Icon(Icons.public, color: GE.primary, size: 22),
          const SizedBox(width: 8),
          Text('Лента',
              style: TextStyle(
                  color: GE.text, fontSize: 20, fontWeight: FontWeight.w800)),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.edit_outlined, color: GE.primary),
            tooltip: 'Новый пост',
            onPressed: _openComposer,
          ),
        ],
      ),
    );
  }

  Widget _sortBar() {
    final current = FeedRepo.instance.sort;
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemBuilder: (_, i) {
          final (id, label) = _sorts[i];
          final active = current == id;
          return InkWell(
            onTap: () => _switchSort(id),
            borderRadius: BorderRadius.circular(18),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: active ? GE.primary.withValues(alpha: 0.18) : GE.glassFill,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: active ? GE.primary : GE.glassBorder,
                  width: active ? 1.2 : 0.6,
                ),
              ),
              alignment: Alignment.center,
              child: Text(label,
                  style: TextStyle(
                    color: active ? GE.primary : GE.sub,
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  )),
            ),
          );
        },
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemCount: _sorts.length,
      ),
    );
  }

  Widget _tagBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: GE.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: GE.primary.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(Icons.tag, size: 14, color: GE.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text('#$_activeTag',
                  style: TextStyle(
                      color: GE.primary, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
            InkWell(
              onTap: _clearTag,
              child: Icon(Icons.close, size: 16, color: GE.primary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    return ValueListenableBuilder<List<FeedPost>>(
      valueListenable: FeedRepo.instance.postsNotifier,
      builder: (_, posts, _) {
        if (_loadingFirst) {
          return Center(child: CircularProgressIndicator(color: GE.primary));
        }
        if (posts.isEmpty) {
          return ValueListenableBuilder<String?>(
            valueListenable: FeedRepo.instance.errorNotifier,
            builder: (_, err, _) => RefreshIndicator(
              color: GE.primary,
              onRefresh: () => FeedRepo.instance.refresh(),
              child: ListView(
                padding: const EdgeInsets.all(32),
                children: [
                  const SizedBox(height: 60),
                  Center(
                    child: GlassCard(
                      lite: true,
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(err != null ? Icons.error_outline : Icons.public_off,
                              color: err != null ? GE.red : GE.sub, size: 32),
                          const SizedBox(height: 8),
                          Text(err != null ? 'Не загрузилось' : 'Лента пуста — будь первым',
                              style: TextStyle(color: GE.text, fontWeight: FontWeight.w600)),
                          if (err != null) ...[
                            const SizedBox(height: 6),
                            Text(err, textAlign: TextAlign.center, maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: GE.sub, fontSize: 11)),
                          ],
                          const SizedBox(height: 12),
                          GlassButton(
                            label: 'Обновить',
                            icon: Icons.refresh,
                            primary: true,
                            onTap: () => FeedRepo.instance.refresh(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return RefreshIndicator(
          color: GE.primary,
          onRefresh: () => FeedRepo.instance.refresh(),
          child: ListView.separated(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 80),
            itemCount: posts.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              if (i == posts.length) {
                return Padding(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: CircularProgressIndicator(color: GE.primary, strokeWidth: 2),
                  ),
                );
              }
              final p = posts[i];
              return _PostCard(
                key: ValueKey(p.id),
                p: p,
                myUsername: _myUsername,
                onOpenTag: _openTag,
                onOpenUser: (u) => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ProfileScreen(username: u),
                )),
                onError: _snack,
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _openComposer() async {
    final ctrl = TextEditingController();
    final picker = ImagePicker();
    final attachments = <FeedMedia>[];
    bool nsfw = false;
    bool publishing = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return StatefulBuilder(builder: (innerCtx, setSheet) {
          final bottom = MediaQuery.of(innerCtx).viewInsets.bottom;
          Future<void> pickImage() async {
            try {
              final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 88);
              if (x == null) return;
              final bytes = await x.readAsBytes();
              setSheet(() => publishing = true);
              try {
                final m = await FeedRepo.instance.uploadMedia(
                  bytes, x.name, 'image/jpeg');
                attachments.add(m);
              } finally {
                setSheet(() => publishing = false);
              }
            } catch (e) {
              _snack('Не загрузилось: $e');
            }
          }

          Future<void> publish() async {
            final text = ctrl.text.trim();
            if (text.isEmpty && attachments.isEmpty) return;
            setSheet(() => publishing = true);
            try {
              await FeedRepo.instance.publish(
                text, media: attachments, isNsfw: nsfw);
              if (!mounted) return;
              Navigator.pop(sheetCtx);
              _snack('Опубликовано');
            } catch (e) {
              _snack('Не опубликовалось: $e');
            } finally {
              setSheet(() => publishing = false);
            }
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + bottom),
            child: GlassCard(
              padding: const EdgeInsets.all(12),
              radius: GE.radiusLg,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Icon(Icons.edit_outlined, color: GE.primary, size: 18),
                    const SizedBox(width: 8),
                    Text('Новый пост',
                        style: TextStyle(color: GE.text, fontWeight: FontWeight.w700)),
                  ]),
                  const SizedBox(height: 10),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    maxLines: 7,
                    minLines: 3,
                    maxLength: 1000,
                    style: TextStyle(color: GE.text),
                    cursorColor: GE.primary,
                    decoration: InputDecoration(
                      hintText: 'Что нового?',
                      hintStyle: TextStyle(color: GE.sub),
                      filled: true,
                      fillColor: Colors.black26,
                      counterStyle: TextStyle(color: GE.sub, fontSize: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  if (attachments.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 80,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemBuilder: (_, i) {
                          final m = attachments[i];
                          return Stack(children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                width: 80, height: 80,
                                color: Colors.black26,
                                child: m.type == 'image'
                                    ? Image.network(_absUrl(m.url), fit: BoxFit.cover,
                                        errorBuilder: (_, _, _) =>
                                            Icon(Icons.image, color: GE.sub))
                                    : Center(
                                        child: Icon(Icons.play_circle_fill,
                                            color: Colors.white70, size: 32)),
                              ),
                            ),
                            Positioned(
                              right: 2, top: 2,
                              child: InkWell(
                                onTap: () => setSheet(() => attachments.removeAt(i)),
                                child: Container(
                                  decoration: const BoxDecoration(
                                      color: Colors.black54, shape: BoxShape.circle),
                                  child: const Icon(Icons.close, color: Colors.white, size: 16),
                                ),
                              ),
                            ),
                          ]);
                        },
                        separatorBuilder: (_, _) => const SizedBox(width: 6),
                        itemCount: attachments.length,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(children: [
                    IconButton(
                      icon: Icon(Icons.image_outlined, color: GE.primary),
                      tooltip: 'Картинка',
                      onPressed: publishing ? null : pickImage,
                    ),
                    InkWell(
                      onTap: () => setSheet(() => nsfw = !nsfw),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: nsfw ? GE.red.withValues(alpha: 0.2) : null,
                          border: Border.all(
                            color: nsfw ? GE.red : GE.glassBorder,
                            width: nsfw ? 1.2 : 0.6,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(nsfw ? Icons.check_box : Icons.check_box_outline_blank,
                              size: 16, color: nsfw ? GE.red : GE.sub),
                          const SizedBox(width: 4),
                          Text('18+',
                              style: TextStyle(
                                color: nsfw ? GE.red : GE.sub,
                                fontSize: 12, fontWeight: FontWeight.w700,
                              )),
                        ]),
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: publishing ? null : () => Navigator.pop(sheetCtx),
                      child: const Text('Отмена'),
                    ),
                    const SizedBox(width: 6),
                    GlassButton(
                      label: 'Опубликовать',
                      icon: Icons.send,
                      primary: true,
                      loading: publishing,
                      onTap: publishing ? null : publish,
                    ),
                  ]),
                ],
              ),
            ),
          );
        });
      },
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
String _absUrl(String url) {
  if (url.startsWith('http')) return url;
  return '${GE.baseUrl}$url';
}

class _PostCard extends StatefulWidget {
  final FeedPost p;
  final String? myUsername;
  final void Function(String tag) onOpenTag;
  final void Function(String username) onOpenUser;
  final void Function(String msg) onError;
  const _PostCard({
    super.key,
    required this.p,
    required this.myUsername,
    required this.onOpenTag,
    required this.onOpenUser,
    required this.onError,
  });
  @override
  State<_PostCard> createState() => _PostCardState();
}

/// Реакции в Ghost: ключи, как в вебе (NOT raw-эмодзи). EMOJI_ORDER + glyph-map.
const List<String> _reactionKeys = ['heart', 'fire', 'laugh', 'sad', 'clap', 'eyes'];
// Кастомные Material иконки для каждого ключа (вместо unicode-эмодзи).
const Map<String, IconData> _reactionIcon = {
  'heart': Icons.favorite,
  'fire': Icons.local_fire_department,
  'laugh': Icons.sentiment_very_satisfied,
  'sad': Icons.sentiment_dissatisfied,
  'clap': Icons.front_hand,
  'eyes': Icons.visibility,
};
const Map<String, Color> _reactionColor = {
  'heart': Color(0xFFef4444),
  'fire': Color(0xFFf97316),
  'laugh': Color(0xFFfacc15),
  'sad': Color(0xFF60a5fa),
  'clap': Color(0xFFfb923c),
  'eyes': Color(0xFFa855f7),
};
const Map<String, String> _reactionLabel = {
  'heart': 'Сердце',
  'fire': 'Огонь',
  'laugh': 'Смех',
  'sad': 'Грусть',
  'clap': 'Хлопок',
  'eyes': 'Глаза',
};

/// Виджет одной реакции — Material-иконка с фирменным цветом.
/// Для legacy raw-эмодзи (приходящих с сервера через chat) возвращает Text.
Widget reactionDisplay(String key, {double size = 14, Color? overrideColor}) {
  final icon = _reactionIcon[key];
  if (icon != null) {
    return Icon(icon, size: size,
        color: overrideColor ?? _reactionColor[key] ?? const Color(0xFFa855f7));
  }
  return Text(key, style: TextStyle(fontSize: size));
}

/// Сортирует counts по EMOJI_ORDER, оставляя legacy-ключи в конце.
List<MapEntry<String, int>> _sortedReactions(Map<String, int> counts) {
  final entries = counts.entries.where((e) => e.value > 0).toList();
  entries.sort((a, b) {
    final ai = _reactionKeys.indexOf(a.key);
    final bi = _reactionKeys.indexOf(b.key);
    if (ai == bi) return a.key.compareTo(b.key);
    if (ai < 0) return 1;
    if (bi < 0) return -1;
    return ai - bi;
  });
  return entries;
}

class _PostCardState extends State<_PostCard> {
  bool _nsfwRevealed = false;
  bool _viewSent = false;

  bool get _isMine =>
      widget.myUsername != null && widget.p.authorUsername == widget.myUsername;

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    return VisibilityAwareView(
      onVisible: () {
        if (_viewSent) return;
        _viewSent = true;
        FeedRepo.instance.markViewed(p.id);
      },
      child: GestureDetector(
        onLongPress: _openReactionPicker,
        onDoubleTap: () async {
          try {
            await FeedRepo.instance.react(p.id, 'heart');
            HapticFeedback.lightImpact();
          } catch (e) { widget.onError('Не вышло: $e'); }
        },
        child: GlassCard(
          lite: true,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (p.isRepost) _repostBadge(),
              if (p.fromChannel != null) _fromChannelBadge(p.fromChannel!),
              _headerRow(p),
              const SizedBox(height: 8),
              // NSFW: рендерим контент всегда, но если не раскрыт — поверх
              // кладём BackdropFilter blur с кнопкой "Показать".
              if (p.isNsfw && !_nsfwRevealed)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(
                    children: [
                      // Реальный контент под блюром
                      Opacity(
                        opacity: 0.85,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (p.content.isNotEmpty) _contentText(p.content),
                            if (p.media.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              _MediaGrid(media: p.media),
                            ],
                          ],
                        ),
                      ),
                      // Backdrop blur поверх
                      Positioned.fill(
                        child: ClipRect(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                            child: Container(color: Colors.black.withValues(alpha: 0.35)),
                          ),
                        ),
                      ),
                      // Кнопка «Показать»
                      Positioned.fill(
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => setState(() => _nsfwRevealed = true),
                            child: Center(child: _nsfwRevealCard()),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                if (p.content.isNotEmpty) _contentText(p.content),
                if (p.content.isNotEmpty)
                  _LinkPreviewWidget(content: p.content),
                if (p.media.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _MediaGrid(media: p.media),
                ],
                if (p.poll != null) ...[
                  const SizedBox(height: 8),
                  _PollWidget(post: p),
                ],
              ],
              const SizedBox(height: 8),
              _stats(p),
              const SizedBox(height: 4),
              _actionsBar(p),
            ],
          ),
        ),
      ),
    );
  }

  Widget _repostBadge() => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          Icon(Icons.repeat, size: 12, color: GE.sub),
          const SizedBox(width: 4),
          Text('репост',
              style: TextStyle(color: GE.sub, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
      );

  Widget _fromChannelBadge(FromChannel ch) {
    final isClickable = ch.username != null;
    final tile = Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: GE.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: GE.primary.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Icon(Icons.campaign_outlined, size: 12, color: GE.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            ch.username != null
                ? 'Канал · ${ch.name} · @${ch.username}'
                : 'Канал · ${ch.name}',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: GE.primary, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ),
        if (isClickable)
          Icon(Icons.open_in_new, size: 11, color: GE.primary),
      ]),
    );
    if (!isClickable) return tile;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => launchUrl(
        Uri.parse('${GE.baseUrl}/c/${ch.username}'),
        mode: LaunchMode.externalApplication,
      ),
      child: tile,
    );
  }

  Widget _headerRow(FeedPost p) {
    return Row(
      children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
          ),
          alignment: Alignment.center,
          child: Text(
            p.authorDisplayName.isNotEmpty
                ? p.authorDisplayName[0].toUpperCase() : '?',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: InkWell(
            onTap: () => widget.onOpenUser(p.authorUsername),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(p.authorDisplayName,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: GE.text, fontSize: 14, fontWeight: FontWeight.w700)),
                    ),
                    if (p.isNsfw) ...[
                      const SizedBox(width: 6),
                      _nsfwBadge(byAdmin: p.nsfwSetByAdmin),
                    ],
                  ],
                ),
                Text(
                  '@${p.authorUsername} · ${_ago(p.createdAt)}'
                  '${p.editedAt != null ? ' · ред.' : ''}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: GE.sub, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
        if (_isMine)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text('это вы',
                style: TextStyle(color: GE.sub, fontSize: 10, fontStyle: FontStyle.italic)),
          )
        else if (!p.followed && widget.myUsername != null)
          InkWell(
            onTap: _toggleFollow,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: GE.primary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: GE.primary.withValues(alpha: 0.5)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.add, size: 12, color: GE.primary),
                const SizedBox(width: 3),
                Text('Подписаться',
                    style: TextStyle(
                        color: GE.primary, fontSize: 10, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        IconButton(
          icon: Icon(Icons.more_horiz, color: GE.sub, size: 18),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: () => _openPostMenu(p),
        ),
      ],
    );
  }

  Widget _nsfwBadge({required bool byAdmin}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: GE.red.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
            color: byAdmin ? GE.red : GE.red.withValues(alpha: 0.5), width: 0.6),
      ),
      child: Text('18+',
          style: TextStyle(color: GE.red, fontSize: 9, fontWeight: FontWeight.w800)),
    );
  }

  /// Компактная плашка «Показать», накладывается поверх размытого контента.
  Widget _nsfwRevealCard() {
    final byAdmin = widget.p.nsfwSetByAdmin;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: GE.red.withValues(alpha: 0.7), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.visibility_off, color: GE.red, size: 22),
          const SizedBox(height: 4),
          Text(byAdmin ? 'Помечено модерацией' : 'Контент 18+',
              style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(height: 2),
          Text(byAdmin ? 'Автор не указал NSFW' : 'Автор пометил как взрослый',
              style: TextStyle(color: Colors.white70, fontSize: 11)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: GE.red.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: GE.red),
            ),
            child: Text('Показать',
                style: TextStyle(color: GE.red, fontWeight: FontWeight.w700, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _contentText(String content) {
    // linkify: #tag и @username превращаем в кликабельные spans.
    final spans = _linkify(content);
    return SelectableText.rich(
      TextSpan(children: spans),
      style: TextStyle(color: GE.text, fontSize: 14, height: 1.4),
    );
  }

  List<InlineSpan> _linkify(String raw) {
    // Сначала режем по любому из шаблонов: #tag или @username.
    final re = RegExp(r'(#[0-9A-Za-zА-Яа-яЁё_]{1,30})|(@[a-zA-Z0-9._]{3,64})', unicode: true);
    final out = <InlineSpan>[];
    int last = 0;
    for (final m in re.allMatches(raw)) {
      if (m.start > last) {
        out.add(TextSpan(text: raw.substring(last, m.start)));
      }
      final hit = m.group(0)!;
      if (hit.startsWith('#')) {
        final tag = hit.substring(1).toLowerCase();
        out.add(TextSpan(
          text: hit,
          style: TextStyle(color: GE.primary, fontWeight: FontWeight.w600),
          recognizer: TapGestureRecognizer()..onTap = () => widget.onOpenTag(tag),
        ));
      } else if (hit.startsWith('@')) {
        final u = hit.substring(1);
        out.add(TextSpan(
          text: hit,
          style: TextStyle(color: GE.blue, fontWeight: FontWeight.w600),
          recognizer: TapGestureRecognizer()..onTap = () => widget.onOpenUser(u),
        ));
      }
      last = m.end;
    }
    if (last < raw.length) {
      out.add(TextSpan(text: raw.substring(last)));
    }
    return out;
  }

  Widget _stats(FeedPost p) {
    if (p.viewsCount == 0 && p.repostsCount == 0) return const SizedBox.shrink();
    return Row(
      children: [
        if (p.viewsCount > 0) ...[
          Icon(Icons.visibility_outlined, size: 12, color: GE.sub),
          const SizedBox(width: 4),
          Text('${_fmtCount(p.viewsCount)}',
              style: TextStyle(color: GE.sub, fontSize: 11)),
          const SizedBox(width: 14),
        ],
        if (p.repostsCount > 0) ...[
          Icon(Icons.repeat, size: 12, color: GE.sub),
          const SizedBox(width: 4),
          Text('${_fmtCount(p.repostsCount)}',
              style: TextStyle(color: GE.sub, fontSize: 11)),
        ],
      ],
    );
  }

  Widget _actionsBar(FeedPost p) {
    final hasMine = p.myReaction != null;
    return Row(
      children: [
        // Heart / your-reaction (показываем твой эмодзи если поставил, иначе ❤️ серый)
        InkWell(
          onTap: () async {
            try {
              await FeedRepo.instance.react(p.id, hasMine ? p.myReaction! : 'heart');
              HapticFeedback.selectionClick();
            } catch (e) { widget.onError('Не вышло: $e'); }
          },
          borderRadius: BorderRadius.circular(20),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: hasMine ? GE.red.withValues(alpha: 0.18) : null,
              borderRadius: BorderRadius.circular(20),
              border: hasMine ? Border.all(color: GE.red.withValues(alpha: 0.5)) : null,
            ),
            child: hasMine
                ? reactionDisplay(p.myReaction!, size: 20)
                : Icon(Icons.favorite_border, size: 20, color: GE.sub),
          ),
        ),
        const SizedBox(width: 4),
        // Реакции от других — компактный ряд в порядке EMOJI_ORDER
        Expanded(
          child: SizedBox(
            height: 28,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final e in _sortedReactions(p.reactions))
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () async {
                        try {
                          await FeedRepo.instance.react(p.id, e.key);
                        } catch (er) { widget.onError('$er'); }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: p.myReaction == e.key
                              ? GE.primary.withValues(alpha: 0.18)
                              : Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(99),
                          border: p.myReaction == e.key
                              ? Border.all(
                                  color: GE.primary.withValues(alpha: 0.6))
                              : null,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            reactionDisplay(e.key, size: 13),
                            const SizedBox(width: 3),
                            Text('${e.value}',
                                style: TextStyle(
                                    color: p.myReaction == e.key
                                        ? GE.primary : GE.sub,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // Комментарии
        InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => CommentsScreen(
              postId: p.id,
              postPreview: p.content,
            ),
          )),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.mode_comment_outlined, color: GE.sub, size: 16),
              const SizedBox(width: 3),
              Text('${p.commentsCount}',
                  style: TextStyle(color: GE.sub, fontSize: 11)),
            ]),
          ),
        ),
        // Репост
        InkWell(
          onTap: p.reposted ? null : () async {
            try {
              await FeedRepo.instance.repost(p.id);
              HapticFeedback.lightImpact();
            } catch (e) { widget.onError('Не репостнулось: $e'); }
          },
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(Icons.repeat,
                size: 16, color: p.reposted ? GE.green : GE.sub),
          ),
        ),
        // Share
        InkWell(
          onTap: () => _openShareSheet(p),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(Icons.share_outlined, color: GE.sub, size: 16),
          ),
        ),
      ],
    );
  }

  Future<void> _toggleFollow() async {
    try {
      await FeedRepo.instance.toggleFollow(widget.p.authorUsername);
      HapticFeedback.selectionClick();
    } catch (e) {
      widget.onError('Не вышло: $e');
    }
  }

  Future<void> _openReactionPicker() async {
    HapticFeedback.mediumImpact();
    final key = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            radius: GE.radiusLg,
            child: SizedBox(
              height: 56,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemBuilder: (_, i) {
                  final k = _reactionKeys[i];
                  final mine = widget.p.myReaction == k;
                  return InkWell(
                    onTap: () => Navigator.pop(ctx, k),
                    borderRadius: BorderRadius.circular(24),
                    child: Tooltip(
                      message: _reactionLabel[k] ?? k,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: mine ? GE.primary.withValues(alpha: 0.2) : null,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: reactionDisplay(k, size: 30),
                      ),
                    ),
                  );
                },
                separatorBuilder: (_, _) => const SizedBox(width: 4),
                itemCount: _reactionKeys.length,
              ),
            ),
          ),
        ),
      ),
    );
    if (key == null || !mounted) return;
    try {
      await FeedRepo.instance.react(widget.p.id, key);
      HapticFeedback.selectionClick();
    } catch (e) { widget.onError('$e'); }
  }

  Future<void> _openShareSheet(FeedPost p) async {
    final url = '${GE.baseUrl}/p/${p.id}';
    final res = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            radius: GE.radiusLg,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(Icons.send, color: GE.primary),
                  title: Text('В Telegram', style: TextStyle(color: GE.text)),
                  onTap: () => Navigator.pop(ctx, 'tg'),
                ),
                ListTile(
                  leading: Icon(Icons.copy, color: GE.primary),
                  title: Text('Копировать ссылку', style: TextStyle(color: GE.text)),
                  onTap: () => Navigator.pop(ctx, 'copy'),
                ),
                ListTile(
                  leading: Icon(Icons.open_in_browser, color: GE.primary),
                  title: Text('Открыть в браузере', style: TextStyle(color: GE.text)),
                  onTap: () => Navigator.pop(ctx, 'open'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (res == null || !mounted) return;
    switch (res) {
      case 'tg':
        await launchUrl(Uri.parse(
            'https://t.me/share/url?url=$url&text=${Uri.encodeComponent("Пост из Ghost")}'));
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: url));
        widget.onError('Ссылка скопирована');
        break;
      case 'open':
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        break;
    }
  }

  Future<void> _openPostMenu(FeedPost p) async {
    HapticFeedback.mediumImpact();
    final mine = _isMine;
    final res = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            radius: GE.radiusLg,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(Icons.share, color: GE.primary),
                  title: Text('Поделиться', style: TextStyle(color: GE.text)),
                  onTap: () => Navigator.pop(ctx, 'share'),
                ),
                ListTile(
                  leading: Icon(Icons.open_in_browser, color: GE.primary),
                  title: Text('Открыть в браузере', style: TextStyle(color: GE.text)),
                  onTap: () => Navigator.pop(ctx, 'open'),
                ),
                if (mine) ...[
                  ListTile(
                    leading: Icon(Icons.edit_outlined, color: GE.primary),
                    title: Text('Редактировать', style: TextStyle(color: GE.text)),
                    onTap: () => Navigator.pop(ctx, 'edit'),
                  ),
                  ListTile(
                    leading: Icon(Icons.delete_outline, color: GE.red),
                    title: Text('Удалить', style: TextStyle(color: GE.red)),
                    onTap: () => Navigator.pop(ctx, 'delete'),
                  ),
                ] else
                  ListTile(
                    leading: Icon(Icons.flag_outlined, color: GE.red),
                    title: Text('Пожаловаться', style: TextStyle(color: GE.red)),
                    onTap: () => Navigator.pop(ctx, 'report'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (res == null || !mounted) return;
    switch (res) {
      case 'share':
        await _openShareSheet(p);
        break;
      case 'open':
        await launchUrl(Uri.parse('${GE.baseUrl}/p/${p.id}'),
            mode: LaunchMode.externalApplication);
        break;
      case 'edit':
        await _openEditDialog(p);
        break;
      case 'delete':
        await _confirmAndDelete(p);
        break;
      case 'report':
        await _openReportSheet(p);
        break;
    }
  }

  Future<void> _openReportSheet(FeedPost p) async {
    final reasons = <(String, String)>[
      ('spam', 'Спам'),
      ('nsfw', '18+ не помечено'),
      ('abuse', 'Оскорбления / травля'),
      ('illegal', 'Незаконный контент'),
      ('scam', 'Мошенничество'),
      ('other', 'Другое'),
    ];
    final commentCtrl = TextEditingController();
    String? selected;
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return StatefulBuilder(builder: (innerCtx, setSheet) {
          final bottom = MediaQuery.of(innerCtx).viewInsets.bottom;
          bool sending = false;
          Future<void> doSend() async {
            if (selected == null) return;
            setSheet(() => sending = true);
            try {
              await ApiClient().socPost('/post/${p.id}/report', {
                'reason': selected,
                'comment': commentCtrl.text.trim(),
              });
              if (!innerCtx.mounted) return;
              Navigator.pop(sheetCtx, true);
            } catch (e) {
              setSheet(() => sending = false);
              ScaffoldMessenger.of(innerCtx).showSnackBar(
                  SnackBar(content: Text('Не отправилось: $e')));
            }
          }
          return Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + bottom),
            child: GlassCard(
              padding: const EdgeInsets.all(16),
              radius: GE.radiusLg,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.flag_outlined, color: GE.red),
                    const SizedBox(width: 8),
                    Text('Пожаловаться на пост',
                        style: TextStyle(
                            color: GE.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                  ]),
                  const SizedBox(height: 4),
                  Text('Анонимно. Модерация рассмотрит за 24 часа.',
                      style: TextStyle(color: GE.sub, fontSize: 11)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: reasons.map((r) {
                      final (key, label) = r;
                      final active = selected == key;
                      return InkWell(
                        onTap: () => setSheet(() => selected = key),
                        borderRadius: BorderRadius.circular(20),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: active
                                ? GE.red.withValues(alpha: 0.18)
                                : GE.glassFill,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: active ? GE.red : GE.glassBorder,
                              width: active ? 1.2 : 0.6,
                            ),
                          ),
                          child: Text(label,
                              style: TextStyle(
                                  color: active ? GE.red : GE.text,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: commentCtrl,
                    maxLines: 3,
                    minLines: 2,
                    maxLength: 300,
                    style: TextStyle(color: GE.text, fontSize: 13),
                    cursorColor: GE.primary,
                    decoration: InputDecoration(
                      hintText: 'Комментарий (опционально)',
                      hintStyle: TextStyle(color: GE.sub),
                      filled: true,
                      fillColor: GE.glassFill,
                      counterStyle:
                          TextStyle(color: GE.sub, fontSize: 10),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: GE.glassBorder)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    TextButton(
                      onPressed: sending
                          ? null
                          : () => Navigator.pop(sheetCtx, false),
                      child: const Text('Отмена'),
                    ),
                    const Spacer(),
                    GlassButton(
                      label: 'Отправить',
                      icon: Icons.send,
                      primary: true,
                      loading: sending,
                      onTap: (selected == null || sending) ? null : doSend,
                    ),
                  ]),
                ],
              ),
            ),
          );
        });
      },
    );
    if (!mounted) return;
    if (sent == true) widget.onError('Жалоба отправлена');
  }

  Future<void> _openEditDialog(FeedPost p) async {
    final ctrl = TextEditingController(text: p.content);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: Text('Редактировать пост', style: TextStyle(color: GE.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 7,
          minLines: 3,
          style: TextStyle(color: GE.text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (next == null || next.isEmpty) return;
    try {
      await FeedRepo.instance.editPost(p.id, text: next);
      widget.onError('Сохранено');
    } catch (e) {
      widget.onError('Не сохранилось: $e');
    }
  }

  Future<void> _confirmAndDelete(FeedPost p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: Text('Удалить пост?', style: TextStyle(color: GE.text)),
        content: Text('Действие нельзя отменить.',
            style: TextStyle(color: GE.sub)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Удалить', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await FeedRepo.instance.deletePost(p.id);
      widget.onError('Удалено');
    } catch (e) {
      widget.onError('Не удалилось: $e');
    }
  }
}

// ────────────────────────────────────────────────────────────────────────
String _ago(dynamic at) {
  if (at == null) return '';
  DateTime dt;
  try {
    dt = (at is int)
        ? DateTime.fromMillisecondsSinceEpoch(at * 1000)
        : DateTime.parse(at.toString());
    if (!dt.isUtc) dt = dt.toUtc();
  } catch (_) { return ''; }
  final s = DateTime.now().toUtc().difference(dt).inSeconds;
  if (s < 60) return 'только что';
  if (s < 3600) return '${s ~/ 60} мин';
  if (s < 86400) return '${s ~/ 3600} ч';
  if (s < 7 * 86400) return '${s ~/ 86400} д';
  return DateFormat('dd.MM').format(dt.toLocal());
}

String _fmtCount(int n) {
  if (n < 1000) return '$n';
  if (n < 1_000_000) return '${(n / 1000).toStringAsFixed(n < 10_000 ? 1 : 0)}K';
  return '${(n / 1_000_000).toStringAsFixed(1)}M';
}

// ────────────────────────────────────────────────────────────────────────
class _MediaGrid extends StatelessWidget {
  final List<FeedMedia> media;
  const _MediaGrid({required this.media});

  @override
  Widget build(BuildContext context) {
    final imgs = media.where((m) => m.type == 'image' || m.type == 'video').toList();
    final auds = media.where((m) => m.type == 'audio').toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (imgs.isNotEmpty) _imageGrid(context, imgs),
        for (final a in auds) Padding(
          padding: const EdgeInsets.only(top: 6),
          child: _AudioTile(url: a.url),
        ),
      ],
    );
  }

  Widget _imageGrid(BuildContext context, List<FeedMedia> imgs) {
    if (imgs.length == 1) {
      return _cell(context, imgs[0], height: 240);
    }
    if (imgs.length == 2) {
      return SizedBox(
        height: 180,
        child: Row(children: [
          Expanded(child: _cell(context, imgs[0])),
          const SizedBox(width: 3),
          Expanded(child: _cell(context, imgs[1])),
        ]),
      );
    }
    if (imgs.length == 3) {
      return SizedBox(
        height: 220,
        child: Row(children: [
          Expanded(child: _cell(context, imgs[0])),
          const SizedBox(width: 3),
          Expanded(
            child: Column(children: [
              Expanded(child: _cell(context, imgs[1])),
              const SizedBox(height: 3),
              Expanded(child: _cell(context, imgs[2])),
            ]),
          ),
        ]),
      );
    }
    // 4+ — сетка 2x2 c overlay '+N' на последней если 5+
    final visible = imgs.length > 4 ? imgs.take(4).toList() : imgs;
    final extra = imgs.length > 4 ? imgs.length - 4 : 0;
    return SizedBox(
      height: 220,
      child: Column(children: [
        Expanded(
          child: Row(children: [
            Expanded(child: _cell(context, visible[0])),
            const SizedBox(width: 3),
            Expanded(child: _cell(context, visible[1])),
          ]),
        ),
        const SizedBox(height: 3),
        Expanded(
          child: Row(children: [
            Expanded(child: _cell(context, visible[2])),
            const SizedBox(width: 3),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _cell(context, visible[3]),
                  if (extra > 0)
                    Container(
                      color: Colors.black54,
                      alignment: Alignment.center,
                      child: Text('+$extra',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                    ),
                ],
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _cell(BuildContext context, FeedMedia m, {double? height}) {
    final isVideo = m.type == 'video';
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: GestureDetector(
        onTap: () => _openViewer(context, m.url, isVideo),
        child: Container(
          height: height,
          color: Colors.black26,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                _absUrl(m.url),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Center(
                    child: Icon(Icons.broken_image, color: GE.sub, size: 32)),
                loadingBuilder: (ctx, child, progress) {
                  if (progress == null) return child;
                  return Center(
                    child: SizedBox(
                      width: 24, height: 24,
                      child: CircularProgressIndicator(
                          color: GE.primary, strokeWidth: 2,
                          value: progress.expectedTotalBytes == null ? null :
                              progress.cumulativeBytesLoaded / progress.expectedTotalBytes!),
                    ),
                  );
                },
              ),
              if (isVideo)
                Center(
                  child: Container(
                    width: 50, height: 50,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black54,
                    ),
                    child: const Icon(Icons.play_arrow, color: Colors.white, size: 30),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _openViewer(BuildContext context, String url, bool isVideo) {
    if (isVideo) {
      launchUrl(Uri.parse(_absUrl(url)), mode: LaunchMode.externalApplication);
      return;
    }
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(8),
        child: Stack(children: [
          InteractiveViewer(
            child: Center(child: Image.network(_absUrl(url))),
          ),
          Positioned(
            top: 0, right: 0,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ]),
      ),
    );
  }
}

class _AudioTile extends StatelessWidget {
  final String url;
  const _AudioTile({required this.url});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () =>
          launchUrl(Uri.parse(_absUrl(url)), mode: LaunchMode.externalApplication),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: GE.glassBorder),
        ),
        child: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: GE.primary.withValues(alpha: 0.2),
            ),
            child: Icon(Icons.play_arrow, color: GE.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Аудио',
                style: TextStyle(color: GE.text, fontSize: 13)),
          ),
        ]),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
/// LinkPreview: парсит первую http(s)-ссылку из контента поста, тянет
/// /linkpreview?url=, рисует карточку с image + title + description.
/// Кэш в памяти на сессию, чтобы не дёргать сервер на каждый rebuild.
class _LinkPreviewWidget extends StatefulWidget {
  final String content;
  const _LinkPreviewWidget({required this.content});

  @override
  State<_LinkPreviewWidget> createState() => _LinkPreviewWidgetState();
}

class _LinkPreviewWidgetState extends State<_LinkPreviewWidget> {
  static final RegExp _urlRe = RegExp(r'\bhttps?://[^\s<>"]+', caseSensitive: false);
  // Process-wide cache: url → preview data | null (отсутствие)
  static final Map<String, Map<String, dynamic>?> _cache = {};
  static final ApiClient _api = ApiClient();
  Map<String, dynamic>? _data;
  bool _loading = false;
  bool _failed = false;
  String? _url;

  @override
  void initState() {
    super.initState();
    _detect();
  }

  void _detect() {
    final m = _urlRe.firstMatch(widget.content);
    if (m == null) return;
    var u = m.group(0)!;
    // обрезаем хвостовую пунктуацию
    u = u.replaceAll(RegExp(r'[.,;!?)]+$'), '');
    _url = u;
    if (_cache.containsKey(u)) {
      _data = _cache[u];
      _failed = _data == null;
      return;
    }
    _load(u);
  }

  Future<void> _load(String u) async {
    setState(() => _loading = true);
    try {
      final r = await _api.socGet('/linkpreview', {'url': u});
      if (!mounted) return;
      if (r is Map && (r['title'] != null || r['image'] != null)) {
        final data = Map<String, dynamic>.from(r);
        _cache[u] = data;
        setState(() { _data = data; _loading = false; });
      } else {
        _cache[u] = null;
        setState(() { _failed = true; _loading = false; });
      }
    } catch (_) {
      if (!mounted) return;
      _cache[u] = null;
      setState(() { _failed = true; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_url == null || _failed) return const SizedBox.shrink();
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: GlassCard(
          lite: true,
          padding: const EdgeInsets.all(10),
          child: Row(children: [
            SizedBox(
              width: 14, height: 14,
              child: CircularProgressIndicator(color: GE.primary, strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_url!,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: GE.sub, fontSize: 11)),
            ),
          ]),
        ),
      );
    }
    if (_data == null) return const SizedBox.shrink();
    final image = _data!['image'] as String?;
    final title = (_data!['title'] as String?) ?? _url!;
    final desc = _data!['description'] as String?;
    final site = (_data!['site'] as String?) ?? Uri.tryParse(_url!)?.host ?? '';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: GlassCard(
        lite: true,
        padding: EdgeInsets.zero,
        onTap: () => launchUrl(Uri.parse(_url!),
            mode: LaunchMode.externalApplication),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(GE.radiusMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (image != null && image.isNotEmpty)
                Image.network(image,
                    height: 140, fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink()),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (site.isNotEmpty)
                      Text(site.toUpperCase(),
                          style: TextStyle(
                              color: GE.primary,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5)),
                    Text(title,
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: GE.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            height: 1.3)),
                    if (desc != null && desc.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(desc,
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: GE.sub, fontSize: 11, height: 1.35)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
/// Грубая «видимость» виджета — вызывает onVisible один раз когда
/// он попал в viewport (для трекинга просмотров поста).
class VisibilityAwareView extends StatefulWidget {
  final Widget child;
  final VoidCallback onVisible;
  const VisibilityAwareView({super.key, required this.child, required this.onVisible});
  @override
  State<VisibilityAwareView> createState() => _VisibilityAwareViewState();
}

class _VisibilityAwareViewState extends State<VisibilityAwareView> {
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _check() {
    if (_fired || !mounted) return;
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.attached) return;
    final pos = ro.localToGlobal(Offset.zero);
    final size = ro.size;
    final screen = MediaQuery.of(context).size;
    if (pos.dy + size.height > 0 && pos.dy < screen.height) {
      _fired = true;
      widget.onVisible();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Перепроверяем при каждом rebuild — достаточно для grep-сравнения с веб-IntersectionObserver.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    return widget.child;
  }
}

/// Виджет опроса/викторины под постом.
/// Если my_vote == null → показывает варианты-кнопки.
/// После голосования → показывает варианты с заполнением + % + total.
/// Quiz: после голосования зелёным подсвечивается correct_idx, красным — мой mismatch.
class _PollWidget extends StatefulWidget {
  final FeedPost post;
  const _PollWidget({required this.post});
  @override
  State<_PollWidget> createState() => _PollWidgetState();
}

class _PollWidgetState extends State<_PollWidget> {
  bool _busy = false;

  Future<void> _vote(int idx) async {
    if (_busy) return;
    final poll = widget.post.poll;
    if (poll == null || poll.myVote != null) return;
    setState(() => _busy = true);
    HapticFeedback.selectionClick();
    try {
      await FeedRepo.instance.votePoll(widget.post.id, idx);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не получилось проголосовать: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final poll = widget.post.poll;
    if (poll == null) return const SizedBox.shrink();
    final voted = poll.myVote != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: GE.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: GE.primary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(
                  poll.isQuiz ? Icons.psychology : Icons.bar_chart,
                  size: 11,
                  color: GE.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  poll.isQuiz ? 'ВИКТОРИНА' : 'ОПРОС',
                  style: TextStyle(
                    color: GE.primary,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                poll.question,
                style: TextStyle(
                  color: GE.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          ...List.generate(poll.options.length, (i) {
            final cnt = poll.counts[i] ?? 0;
            final pct = poll.total == 0 ? 0 : (cnt * 100 / poll.total).round();
            final isMine = poll.myVote == i;
            final isCorrect = (poll.correctIdx != null && poll.correctIdx == i);
            final isWrongMine = voted && isMine &&
                (poll.correctIdx != null && poll.correctIdx != i);

            Color fill = GE.primary.withValues(alpha: 0.18);
            Color border = GE.glassBorder;
            IconData? badge;
            Color? badgeColor;
            if (voted) {
              if (isCorrect) {
                fill = const Color(0xFF22c55e).withValues(alpha: 0.22);
                border = const Color(0xFF22c55e);
                badge = Icons.check_circle;
                badgeColor = const Color(0xFF22c55e);
              } else if (isWrongMine) {
                fill = const Color(0xFFef4444).withValues(alpha: 0.22);
                border = const Color(0xFFef4444);
                badge = Icons.cancel;
                badgeColor = const Color(0xFFef4444);
              } else if (isMine) {
                fill = GE.primary.withValues(alpha: 0.28);
                border = GE.primary;
              }
            }

            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                onTap: voted || _busy ? null : () => _vote(i),
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: border),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 11),
                      child: Row(children: [
                        Expanded(
                          child: Text(
                            poll.options[i],
                            style: TextStyle(
                                color: GE.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (badge != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Icon(badge, size: 14, color: badgeColor),
                          ),
                        if (voted)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              '$pct%',
                              style: TextStyle(
                                color: GE.text,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          ),
                      ]),
                    ),
                    // fill-полоска снизу (только после голосования)
                    if (voted)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: FractionallySizedBox(
                              widthFactor: poll.total == 0 ? 0 : cnt / poll.total,
                              alignment: Alignment.centerLeft,
                              child: Container(color: fill),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          }),
          if (voted) Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${poll.total} голос${_plural(poll.total)}',
              style: TextStyle(color: GE.sub, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  String _plural(int n) {
    final n10 = n % 10, n100 = n % 100;
    if (n10 == 1 && n100 != 11) return '';
    if (n10 >= 2 && n10 <= 4 && (n100 < 10 || n100 >= 20)) return 'а';
    return 'ов';
  }
}
