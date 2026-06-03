// FeedScreen — нативная лента. Список постов с реакциями, репостом,
// composer для нового поста. На pull-to-refresh — перезагрузка.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../services/feed_repo.dart';
import '../widgets/glass.dart';

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});
  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final _scroll = ScrollController();
  bool _loadingFirst = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _initLoad();
  }

  Future<void> _initLoad() async {
    if (FeedRepo.instance.postsNotifier.value.isEmpty) {
      await FeedRepo.instance.loadMore();
    }
    if (mounted) setState(() => _loadingFirst = false);
  }

  void _onScroll() {
    if (_scroll.position.pixels >
        _scroll.position.maxScrollExtent - 600) {
      FeedRepo.instance.loadMore();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
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
        ),
        Expanded(
          child: ValueListenableBuilder<List<FeedPost>>(
            valueListenable: FeedRepo.instance.postsNotifier,
            builder: (_, posts, _) {
              if (_loadingFirst) {
                return Center(child: CircularProgressIndicator(color: GE.primary));
              }
              if (posts.isEmpty) {
                return Center(
                  child: GlassCard(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.public_off, color: GE.sub, size: 32),
                        const SizedBox(height: 8),
                        Text('Лента пуста — будь первым',
                            style: TextStyle(color: GE.text)),
                      ],
                    ),
                  ),
                );
              }
              return RefreshIndicator(
                color: GE.primary,
                onRefresh: FeedRepo.instance.refresh,
                child: ListView.separated(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 80),
                  itemCount: posts.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    if (i == posts.length) {
                      return Padding(
                        padding: const EdgeInsets.all(20),
                        child: Center(
                          child: CircularProgressIndicator(
                              color: GE.primary, strokeWidth: 2),
                        ),
                      );
                    }
                    return _PostCard(posts[i]);
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _openComposer() async {
    final ctrl = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final bottom = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + bottom),
          child: GlassCard(
            padding: const EdgeInsets.all(12),
            radius: GE.radiusLg,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(Icons.edit_outlined, color: GE.primary, size: 18),
                    const SizedBox(width: 8),
                    Text('Новый пост',
                        style: TextStyle(color: GE.text, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  maxLines: 6,
                  minLines: 3,
                  style: TextStyle(color: GE.text),
                  cursorColor: GE.primary,
                  decoration: InputDecoration(
                    hintText: 'Что нового?',
                    hintStyle: TextStyle(color: GE.sub),
                    filled: true,
                    fillColor: Colors.black26,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Отмена'),
                    ),
                    const SizedBox(width: 8),
                    GlassButton(
                      label: 'Опубликовать',
                      icon: Icons.send,
                      primary: true,
                      onTap: () async {
                        final text = ctrl.text.trim();
                        if (text.isEmpty) return;
                        Navigator.pop(ctx);
                        try {
                          await FeedRepo.instance.publish(text);
                        } catch (e) {
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Не опубликовалось: $e')),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
class _PostCard extends StatefulWidget {
  final FeedPost p;
  const _PostCard(this.p);
  @override
  State<_PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<_PostCard> {
  static const _reactionEmojis = ['❤', '🔥', '👍', '😂', '😮', '😢'];

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    return GestureDetector(
      onLongPress: () => _openPostMenu(p),
      child: GlassCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
                ),
                alignment: Alignment.center,
                child: Text(
                  p.authorDisplayName.isNotEmpty
                      ? p.authorDisplayName[0].toUpperCase() : '?',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.authorDisplayName,
                        style: TextStyle(
                            color: GE.text, fontSize: 14, fontWeight: FontWeight.w600)),
                    Text('@${p.authorUsername} · ${_fmtTime(p.createdAt)}',
                        style: TextStyle(color: GE.sub, fontSize: 11)),
                  ],
                ),
              ),
              if (p.isNsfw)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: GE.red.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('18+',
                        style: TextStyle(color: GE.red, fontSize: 10, fontWeight: FontWeight.w700)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(p.content,
              style: TextStyle(color: GE.text, fontSize: 14, height: 1.4)),
          const SizedBox(height: 10),
          _reactionBar(),
        ],
      ),
      ),
    );
  }

  Future<void> _openPostMenu(FeedPost p) async {
    HapticFeedback.mediumImpact();
    final url = 'https://ghostecos.duckdns.org/p/${p.id}';
    await showModalBottomSheet<void>(
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
                  onTap: () async {
                    Navigator.pop(ctx);
                    await launchUrl(Uri.parse('https://t.me/share/url?url=$url&text=Пост из Ghost'));
                  },
                ),
                ListTile(
                  leading: Icon(Icons.copy, color: GE.primary),
                  title: Text('Копировать ссылку', style: TextStyle(color: GE.text)),
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: url));
                    if (mounted) {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Ссылка скопирована')),
                      );
                    }
                  },
                ),
                ListTile(
                  leading: Icon(Icons.open_in_browser, color: GE.primary),
                  title: Text('Открыть в браузере', style: TextStyle(color: GE.text)),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                  },
                ),
                ListTile(
                  leading: Icon(Icons.flag_outlined, color: GE.red),
                  title: Text('Пожаловаться', style: TextStyle(color: GE.red)),
                  onTap: () => Navigator.pop(ctx),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _reactionBar() {
    final p = widget.p;
    return Row(
      children: [
        for (final e in _reactionEmojis)
          _reactionChip(e, p.reactions[e] ?? 0, active: p.myReaction == e),
        const Spacer(),
        IconButton(
          tooltip: 'Комментарии',
          icon: Icon(Icons.mode_comment_outlined, color: GE.sub, size: 18),
          onPressed: () {},
        ),
        Text('${p.commentsCount}',
            style: TextStyle(color: GE.sub, fontSize: 12)),
        const SizedBox(width: 8),
        IconButton(
          tooltip: p.reposted ? 'Уже репостнул' : 'Репост',
          icon: Icon(Icons.repeat,
              color: p.reposted ? GE.green : GE.sub, size: 18),
          onPressed: p.reposted ? null : () async {
            try {
              await FeedRepo.instance.repost(p.id);
            } catch (e) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Не репостнулось: $e')),
              );
            }
          },
        ),
      ],
    );
  }

  Widget _reactionChip(String emoji, int count, {bool active = false}) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => FeedRepo.instance.react(widget.p.id, emoji),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: active ? GE.primary.withValues(alpha: 0.22) : null,
            borderRadius: BorderRadius.circular(14),
            border: active
                ? Border.all(color: GE.primary.withValues(alpha: 0.6), width: 1)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 14)),
              if (count > 0) ...[
                const SizedBox(width: 3),
                Text('$count',
                    style: TextStyle(color: GE.sub, fontSize: 11)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _fmtTime(dynamic at) {
    if (at == null) return '';
    DateTime dt;
    try {
      dt = at is int
          ? DateTime.fromMillisecondsSinceEpoch(at * 1000)
          : DateTime.parse(at.toString());
    } catch (_) { return ''; }
    final now = DateTime.now();
    final local = dt.toLocal();
    final diff = now.difference(local);
    if (diff.inMinutes < 1) return 'только что';
    if (diff.inMinutes < 60) return '${diff.inMinutes} мин';
    if (diff.inHours < 24) return '${diff.inHours} ч';
    if (diff.inDays < 7) return '${diff.inDays} д';
    return DateFormat('dd.MM').format(local);
  }
}
