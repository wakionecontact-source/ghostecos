// SocialPane — обёртка над разделами GhostSocial (внутри главного таба «Соц»
// в bottom-nav). Имеет собственный верхний tab-bar:
//   Лента / Миниски / Поиск / Уведомления / +Пост
//
// Каждый таб — отдельный экран, переключение через IndexedStack (сохраняет
// scroll-position при переходах). FeedScreen используется в embedded=true.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import '../theme.dart';
import '../services/feed_repo.dart';
import '../services/social_repo.dart';
import '../widgets/glass.dart';
import 'feed_screen.dart';
import 'miniska_create_screen.dart';
import 'profile_screen.dart';

class SocialPane extends StatefulWidget {
  const SocialPane({super.key});
  @override
  State<SocialPane> createState() => _SocialPaneState();
}

class _SocialPaneState extends State<SocialPane> {
  int _index = 0;
  static const _tabs = [
    ('Лента', Icons.home_outlined, Icons.home),
    ('Миниски', Icons.movie_outlined, Icons.movie),
    ('Поиск', Icons.search, Icons.search),
    ('Уведомления', Icons.notifications_outlined, Icons.notifications),
  ];

  @override
  void initState() {
    super.initState();
    SocialRepo.instance.fetchUnreadCount();
  }

  void _switch(int i) {
    HapticFeedback.selectionClick();
    setState(() => _index = i);
  }

  Future<void> _openComposer() async {
    HapticFeedback.selectionClick();
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
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Картинка не загрузилась: $e')));
            }
          }

          Future<void> publish() async {
            final text = ctrl.text.trim();
            if (text.isEmpty && attachments.isEmpty) return;
            setSheet(() => publishing = true);
            try {
              await FeedRepo.instance.publish(text, media: attachments, isNsfw: nsfw);
              if (!mounted) return;
              Navigator.pop(sheetCtx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Опубликовано')));
              // Переключим на ленту чтобы юзер увидел свой пост
              setState(() => _index = 0);
            } catch (e) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Не опубликовалось: $e')));
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
                        itemBuilder: (_, i) => Stack(children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              width: 80, height: 80,
                              color: Colors.black26,
                              child: Image.network(
                                attachments[i].url.startsWith('http')
                                    ? attachments[i].url
                                    : '${GE.baseUrl}${attachments[i].url}',
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    Icon(Icons.image, color: GE.sub),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 2, top: 2,
                            child: InkWell(
                              onTap: () => setSheet(() => attachments.removeAt(i)),
                              child: Container(
                                decoration: const BoxDecoration(
                                    color: Colors.black54, shape: BoxShape.circle),
                                child: const Icon(Icons.close,
                                    color: Colors.white, size: 16),
                              ),
                            ),
                          ),
                        ]),
                        separatorBuilder: (_, _) => const SizedBox(width: 6),
                        itemCount: attachments.length,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(children: [
                    InkWell(
                      onTap: publishing ? null : pickImage,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(Icons.image_outlined,
                            color: GE.primary, size: 22),
                      ),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () => setSheet(() => nsfw = !nsfw),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _header(),
        _topTabs(),
        Expanded(
          child: IndexedStack(
            index: _index,
            children: const [
              FeedScreen(embedded: true),
              _MiniskaTab(),
              _SearchTab(),
              _NotifTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(children: [
        Text('GhostSocial',
            style: TextStyle(
                color: GE.text,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5)),
        const Spacer(),
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(99),
            onTap: _openComposer,
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.add_rounded, size: 24),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _topTabs() {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemBuilder: (_, i) {
          final (label, iconOut, iconFill) = _tabs[i];
          final active = i == _index;
          Widget child = InkWell(
            onTap: () => _switch(i),
            borderRadius: BorderRadius.circular(20),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                gradient: active
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          GE.primary.withValues(alpha: 0.30),
                          GE.primary2.withValues(alpha: 0.18),
                        ],
                      )
                    : LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.alphaBlend(
                              Colors.white.withValues(alpha: 0.08), GE.glassFill),
                          GE.glassFill,
                        ],
                      ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: active
                      ? GE.primary.withValues(alpha: 0.75)
                      : Colors.white.withValues(alpha: 0.14),
                  width: active ? 1.2 : 0.8,
                ),
                boxShadow: [
                  active
                      ? BoxShadow(
                          color: GE.primary.withValues(alpha: 0.32),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        )
                      : BoxShadow(
                          color: Colors.black.withValues(alpha: 0.20),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                ],
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(active ? iconFill : iconOut,
                    size: 14, color: active ? Colors.white : GE.sub),
                const SizedBox(width: 4),
                Text(label,
                    style: TextStyle(
                      color: active ? Colors.white : GE.sub,
                      fontSize: 12,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    )),
              ]),
            ),
          );
          // На «Уведомления» — бейдж с количеством непрочитанных
          if (i == 3) {
            return ValueListenableBuilder<int>(
              valueListenable: SocialRepo.instance.unreadNotifNotifier,
              builder: (_, count, _) => Stack(clipBehavior: Clip.none, children: [
                child,
                if (count > 0)
                  Positioned(
                    right: -4, top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: GE.red,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        count > 99 ? '99+' : '$count',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
              ]),
            );
          }
          return child;
        },
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemCount: _tabs.length,
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// Tab: Миниски
class _MiniskaTab extends StatefulWidget {
  const _MiniskaTab();
  @override
  State<_MiniskaTab> createState() => _MiniskaTabState();
}

class _MiniskaTabState extends State<_MiniskaTab> {
  List<FeedPost> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items = await SocialRepo.instance.fetchMiniska();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _openCreate() async {
    final created = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const MiniskaCreateScreen()));
    if (created == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_loading) {
      body = Center(child: CircularProgressIndicator(color: GE.primary));
    } else if (_error != null) {
      body = _emptyState('Не загрузилось', _error!, _load);
    } else if (_items.isEmpty) {
      body = _emptyState('Минисок пока нет',
          'Короткие видео-посты появятся когда кто-то их опубликует.', _load);
    } else {
      body = RefreshIndicator(
        color: GE.primary,
        onRefresh: _load,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 80),
          itemCount: _items.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (_, i) => _MiniPostCard(p: _items[i]),
        ),
      );
    }
    return Stack(children: [
      body,
      Positioned(
        right: 16, bottom: 16,
        child: FloatingActionButton.extended(
          backgroundColor: GE.primary,
          foregroundColor: Colors.white,
          icon: const Icon(Icons.videocam, size: 18),
          label: const Text('Новая'),
          onPressed: _openCreate,
        ),
      ),
    ]);
  }

  Widget _emptyState(String title, String body, VoidCallback onRetry) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        Center(
          child: GlassCard(
            lite: true,
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.movie_outlined, color: GE.sub, size: 32),
              const SizedBox(height: 8),
              Text(title,
                  style: TextStyle(color: GE.text, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(body,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GE.sub, fontSize: 12)),
              const SizedBox(height: 12),
              GlassButton(
                label: 'Обновить',
                icon: Icons.refresh,
                primary: true,
                onTap: onRetry,
              ),
            ]),
          ),
        ),
      ],
    );
  }
}

class _MiniPostCard extends StatelessWidget {
  final FeedPost p;
  const _MiniPostCard({required this.p});
  @override
  Widget build(BuildContext context) {
    final video = p.media.firstWhere(
      (m) => m.type == 'video',
      orElse: () => p.media.isEmpty
          ? const FeedMedia(type: 'image', url: '')
          : p.media.first,
    );
    return GlassCard(
      lite: true,
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ProfileScreen(username: p.authorUsername),
              )),
              child: Container(
                width: 32, height: 32,
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
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(p.authorDisplayName,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: GE.text, fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 8),
          if (video.url.isNotEmpty)
            Container(
              height: 200,
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.play_circle, color: Colors.white70, size: 48),
                const SizedBox(height: 6),
                Text('Миниска · ${video.type}',
                    style: TextStyle(color: GE.sub, fontSize: 11)),
              ]),
            ),
          if (p.content.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(p.content,
                maxLines: 3, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: GE.text, fontSize: 13)),
          ],
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// Tab: Поиск
class _SearchTab extends StatefulWidget {
  const _SearchTab();
  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  SearchResult? _result;
  bool _searching = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      setState(() => _result = null);
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final r = await SocialRepo.instance.search(q.trim());
        if (!mounted) return;
        setState(() {
          _result = r;
          _searching = false;
        });
      } catch (_) {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: GlassInput(
            controller: _ctrl,
            hint: 'Поиск: @username или текст поста',
            icon: Icons.search,
            onChanged: _onChanged,
            suffix: _ctrl.text.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.close, color: GE.sub, size: 18),
                    onPressed: () {
                      _ctrl.clear();
                      _onChanged('');
                    },
                  )
                : null,
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_searching && _result == null) {
      return Center(child: CircularProgressIndicator(color: GE.primary));
    }
    if (_result == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text('Введи запрос. @username — поиск юзеров, иначе — текст постов.',
              textAlign: TextAlign.center,
              style: TextStyle(color: GE.sub, fontSize: 13)),
        ),
      );
    }
    final r = _result!;
    if (r.results.isEmpty) {
      return Center(
        child: Text('Ничего не найдено', style: TextStyle(color: GE.sub)),
      );
    }
    if (r.type == 'users') {
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 80),
        itemCount: r.results.length,
        separatorBuilder: (_, _) => const SizedBox(height: 2),
        itemBuilder: (_, i) {
          final u = Map<String, dynamic>.from(r.results[i] as Map);
          final username = (u['username'] as String?) ?? '';
          final display = (u['display_name'] as String?) ?? username;
          final posts = (u['posts_count'] as num?)?.toInt() ?? 0;
          return InkWell(
            borderRadius: BorderRadius.circular(GE.radiusMd),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ProfileScreen(username: username),
            )),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    display.isNotEmpty ? display[0].toUpperCase() : '?',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(display,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: GE.text, fontWeight: FontWeight.w600, fontSize: 14)),
                      Text('@$username · постов: $posts',
                          style: TextStyle(color: GE.sub, fontSize: 11)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: GE.sub),
              ]),
            ),
          );
        },
      );
    }
    // Posts
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 80),
      itemCount: r.results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final m = Map<String, dynamic>.from(r.results[i] as Map);
        final username = (m['username'] as String?) ?? 'anon';
        final display = (m['display_name'] as String?) ?? username;
        final content = (m['content'] as String?) ?? '';
        return GlassCard(
          lite: true,
          padding: const EdgeInsets.all(12),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ProfileScreen(username: username),
          )),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  width: 30, height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    display.isNotEmpty ? display[0].toUpperCase() : '?',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                Text('@$username',
                    style: TextStyle(color: GE.sub, fontSize: 12)),
              ]),
              const SizedBox(height: 6),
              Text(content,
                  maxLines: 4, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: GE.text, fontSize: 14)),
            ],
          ),
        );
      },
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// Tab: Уведомления
class _NotifTab extends StatefulWidget {
  const _NotifTab();
  @override
  State<_NotifTab> createState() => _NotifTabState();
}

class _NotifTabState extends State<_NotifTab> {
  List<NotifItem> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await SocialRepo.instance.fetchNotifications();
      if (!mounted) return;
      // Помечаем прочитанными при открытии вкладки.
      final unread = r.items.where((n) => !n.isRead).map((n) => n.id).toList();
      if (unread.isNotEmpty) {
        unawaited(SocialRepo.instance.markRead(unread));
      }
      setState(() {
        _items = r.items;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: GE.primary));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline, color: GE.red),
            const SizedBox(height: 8),
            Text(_error!, textAlign: TextAlign.center,
                style: TextStyle(color: GE.sub, fontSize: 12)),
          ]),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.notifications_none, color: GE.sub, size: 32),
            const SizedBox(height: 8),
            Text('Уведомлений нет',
                style: TextStyle(color: GE.sub, fontSize: 13)),
          ]),
        ),
      );
    }
    return RefreshIndicator(
      color: GE.primary,
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 80),
        itemCount: _items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 2),
        itemBuilder: (_, i) => _NotifTile(item: _items[i]),
      ),
    );
  }
}

class _NotifTile extends StatelessWidget {
  final NotifItem item;
  const _NotifTile({required this.item});

  IconData _iconFor(String type) {
    switch (type) {
      case 'react': return Icons.favorite;
      case 'comment': return Icons.mode_comment;
      case 'follow': return Icons.person_add;
      case 'mention': return Icons.alternate_email;
      case 'repost': return Icons.repeat;
      default: return Icons.notifications;
    }
  }

  String _labelFor(String type, String actor) {
    switch (type) {
      case 'react': return '$actor поставил реакцию';
      case 'comment': return '$actor прокомментировал';
      case 'follow': return '$actor подписался на тебя';
      case 'mention': return '$actor упомянул тебя';
      case 'repost': return '$actor репостнул';
      default: return '$actor — $type';
    }
  }

  String _fmtAt(dynamic at) {
    if (at == null) return '';
    try {
      DateTime dt;
      if (at is int) {
        dt = DateTime.fromMillisecondsSinceEpoch(at * 1000);
      } else {
        dt = DateTime.parse(at.toString());
      }
      if (!dt.isUtc) dt = dt.toUtc();
      final s = DateTime.now().toUtc().difference(dt).inSeconds;
      if (s < 60) return 'только что';
      if (s < 3600) return '${s ~/ 60} мин';
      if (s < 86400) return '${s ~/ 3600} ч';
      if (s < 7 * 86400) return '${s ~/ 86400} д';
      return DateFormat('dd.MM').format(dt.toLocal());
    } catch (_) { return ''; }
  }

  @override
  Widget build(BuildContext context) {
    final actor = item.actorName ?? item.actorUsername ?? '?';
    return InkWell(
      borderRadius: BorderRadius.circular(GE.radiusMd),
      onTap: item.actorUsername == null
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ProfileScreen(username: item.actorUsername!),
              )),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: item.isRead ? null : GE.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(GE.radiusMd),
        ),
        child: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: GE.primary.withValues(alpha: 0.18),
            ),
            child: Icon(_iconFor(item.type), color: GE.primary, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_labelFor(item.type, actor),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: GE.text, fontSize: 13, fontWeight: FontWeight.w600)),
                if (item.preview != null && item.preview!.isNotEmpty)
                  Text(item.preview!,
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: GE.sub, fontSize: 12)),
                Text(_fmtAt(item.createdAt),
                    style: TextStyle(color: GE.muted, fontSize: 11)),
              ],
            ),
          ),
          if (!item.isRead)
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle, color: GE.primary,
              ),
            ),
        ]),
      ),
    );
  }
}
