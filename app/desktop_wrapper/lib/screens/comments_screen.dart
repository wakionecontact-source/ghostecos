// CommentsScreen v2 — комменты с reactions + replies + sort (top/new).
// Backend:
//   GET  /com/get/{post_id}?sort=top|new&offset=N&limit=M
//        → {comments:[{id,text,created_at,parent_id,reply_to_id,username,
//                       display_name,reactions:{counts,your_emoji,total},
//                       replies_count}], has_more, total}
//   GET  /com/replies/{cid}?offset=N&limit=M
//        → {replies:[...+ reply_to_username, reply_to_text], has_more, total}
//   POST /com/{post_id}     body {text, parent_comment_id?}  → создать
//   POST /com/{cid}/react   body {emoji}                     → toggle реакция
//   DELETE /com/{cid}                                        → удалить свой
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../theme.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../widgets/glass.dart';
import 'profile_screen.dart';

class CommentsScreen extends StatefulWidget {
  final int postId;
  final String? postPreview;
  const CommentsScreen({super.key, required this.postId, this.postPreview});
  @override
  State<CommentsScreen> createState() => _CommentsScreenState();
}

class _CommentsScreenState extends State<CommentsScreen> {
  final _api = ApiClient();
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  List<_Comment> _items = [];
  final Map<int, List<_Comment>> _replies = {};
  final Set<int> _repliesLoading = {};
  bool _loading = true;
  bool _sending = false;
  bool _hasMore = true;
  int _offset = 0;
  String _sort = 'top';
  String? _myUsername;

  int? _replyParentCid;
  String? _replyToUsername;
  String? _replyToText;

  @override
  void initState() {
    super.initState();
    _init();
    _scroll.addListener(() {
      if (!_loading && _hasMore &&
          _scroll.position.pixels > _scroll.position.maxScrollExtent - 200) {
        _loadMore();
      }
    });
  }

  Future<void> _init() async {
    _myUsername = await AuthService.username();
    await _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _items = [];
        _offset = 0;
        _hasMore = true;
        _replies.clear();
      });
    }
    await _loadMore();
  }

  Future<void> _loadMore() async {
    try {
      final r = await _api.socGet('/com/get/${widget.postId}', {
        'offset': _offset, 'limit': 15, 'sort': _sort,
      });
      if (!mounted) return;
      if (r is Map) {
        final list = (r['comments'] as List?) ?? const [];
        final fresh = list.whereType<Map>()
            .map((m) => _Comment.fromMap(Map<String, dynamic>.from(m)))
            .toList();
        setState(() {
          _items.addAll(fresh);
          _offset += fresh.length;
          _hasMore = (r['has_more'] as bool?) ?? false;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadReplies(int parentCid) async {
    if (_repliesLoading.contains(parentCid)) return;
    setState(() => _repliesLoading.add(parentCid));
    try {
      final r = await _api.socGet('/com/replies/$parentCid',
          {'offset': 0, 'limit': 20});
      if (!mounted) return;
      if (r is Map) {
        final list = (r['replies'] as List?) ?? const [];
        setState(() {
          _replies[parentCid] = list.whereType<Map>()
              .map((m) => _Comment.fromMap(Map<String, dynamic>.from(m)))
              .toList();
        });
      }
    } catch (_) {}
    finally {
      if (mounted) setState(() => _repliesLoading.remove(parentCid));
    }
  }

  void _toggleReplies(int parentCid) {
    if (_replies.containsKey(parentCid)) {
      setState(() => _replies.remove(parentCid));
    } else {
      _loadReplies(parentCid);
    }
  }

  void _enterReplyMode(_Comment c) {
    setState(() {
      _replyParentCid = c.id;
      _replyToUsername = c.username;
      _replyToText = c.text;
    });
    HapticFeedback.selectionClick();
  }

  void _exitReplyMode() {
    setState(() {
      _replyParentCid = null;
      _replyToUsername = null;
      _replyToText = null;
    });
  }

  Future<void> _send() async {
    final t = _ctrl.text.trim();
    if (t.isEmpty || _sending) return;
    setState(() => _sending = true);
    final replyParent = _replyParentCid;
    try {
      final body = <String, dynamic>{'text': t};
      if (replyParent != null) body['parent_comment_id'] = replyParent;
      await _api.socPost('/com/${widget.postId}', body);
      _ctrl.clear();
      _exitReplyMode();
      HapticFeedback.lightImpact();
      if (replyParent != null) {
        await _loadReplies(replyParent);
        final idx = _items.indexWhere((x) => x.id == replyParent);
        if (idx >= 0) {
          setState(() => _items[idx].repliesCount = _items[idx].repliesCount + 1);
        }
      } else {
        await _load(reset: true);
      }
    } catch (e) {
      _snack('Не отправилось: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _toggleReaction(_Comment c, String emoji) async {
    final prev = c.yourEmoji;
    final prevCounts = Map<String, int>.from(c.counts);
    setState(() {
      if (prev == emoji) {
        c.yourEmoji = null;
        c.counts[emoji] = ((c.counts[emoji] ?? 1) - 1).clamp(0, 9999);
        if ((c.counts[emoji] ?? 0) == 0) c.counts.remove(emoji);
      } else {
        if (prev != null) {
          c.counts[prev] = ((c.counts[prev] ?? 1) - 1).clamp(0, 9999);
          if ((c.counts[prev] ?? 0) == 0) c.counts.remove(prev);
        }
        c.yourEmoji = emoji;
        c.counts[emoji] = (c.counts[emoji] ?? 0) + 1;
      }
    });
    try {
      final r = await _api.socPost('/com/${c.id}/react', {'emoji': emoji});
      if (!mounted) return;
      if (r is Map) {
        setState(() {
          c.yourEmoji = r['your_emoji'] as String?;
          c.counts = <String, int>{};
          final m = r['counts'];
          if (m is Map) {
            m.forEach((k, v) {
              if (v is num) c.counts[k.toString()] = v.toInt();
            });
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() {
        c.yourEmoji = prev;
        c.counts = prevCounts;
      });
    }
  }

  void _setSort(String s) {
    if (s == _sort) return;
    setState(() => _sort = s);
    _load(reset: true);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: true,
      appBar: GlassAppBar(showBack: true, titleText: 'Комментарии'),
      body: Column(
        children: [
          if (widget.postPreview != null && widget.postPreview!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: GlassCard(
                lite: true,
                padding: const EdgeInsets.all(10),
                child: Text(widget.postPreview!,
                    maxLines: 3, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: GE.sub, fontSize: 12, height: 1.35)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(children: [
              _SortChip(
                icon: Icons.local_fire_department_outlined,
                label: 'Топ',
                active: _sort == 'top',
                onTap: () => _setSort('top'),
              ),
              const SizedBox(width: 6),
              _SortChip(
                icon: Icons.schedule,
                label: 'Новые',
                active: _sort == 'new',
                onTap: () => _setSort('new'),
              ),
            ]),
          ),
          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator(color: GE.primary))
                : _items.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.mode_comment_outlined,
                                color: GE.sub, size: 32),
                            const SizedBox(height: 8),
                            Text('Пусто. Будь первым.',
                                style: TextStyle(color: GE.sub, fontSize: 13)),
                          ]),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                        itemCount: _items.length + 1,
                        itemBuilder: (_, i) {
                          if (i == _items.length) {
                            return _hasMore
                                ? Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Center(
                                      child: CircularProgressIndicator(
                                          color: GE.primary, strokeWidth: 2),
                                    ),
                                  )
                                : const _NoMore();
                          }
                          final c = _items[i];
                          return _CommentTile(
                            c: c,
                            myUsername: _myUsername,
                            onReply: () => _enterReplyMode(c),
                            onReact: (em) => _toggleReaction(c, em),
                            onToggleReplies: () => _toggleReplies(c.id),
                            replies: _replies[c.id],
                            repliesLoading: _repliesLoading.contains(c.id),
                            onReactReply: (r, em) => _toggleReaction(r, em),
                            onReplyToReply: (r) => _enterReplyMode(r),
                          );
                        },
                      ),
          ),
          if (_replyParentCid != null) _replyBanner(),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: GlassCard(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                radius: GE.radiusLg,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ctrl,
                        minLines: 1, maxLines: 4, maxLength: 500,
                        style: TextStyle(color: GE.text, fontSize: 14),
                        cursorColor: GE.primary,
                        decoration: InputDecoration(
                          hintText: _replyParentCid != null
                              ? 'Ответить @${_replyToUsername ?? ''}...'
                              : 'Комментарий',
                          hintStyle: TextStyle(color: GE.sub),
                          border: InputBorder.none,
                          counterText: '',
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                      ),
                    ),
                    InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _sending ? null : _send,
                      child: Container(
                        width: 38, height: 38,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
                        ),
                        alignment: Alignment.center,
                        child: _sending
                            ? const SizedBox(
                                width: 14, height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.send, color: Colors.white, size: 16),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _replyBanner() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Container(
        decoration: BoxDecoration(
          color: GE.primary.withValues(alpha: 0.10),
          border: Border(left: BorderSide(color: GE.primary, width: 3)),
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(6),
            bottomRight: Radius.circular(6),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Ответ @${_replyToUsername ?? ''}',
                    style: TextStyle(
                        color: GE.primary, fontSize: 11, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(_replyToText ?? '',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: GE.sub, fontSize: 12)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, color: GE.sub, size: 18),
            onPressed: _exitReplyMode,
            tooltip: 'Отменить',
            visualDensity: VisualDensity.compact,
          ),
        ]),
      ),
    );
  }
}

class _SortChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _SortChip({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? GE.primary.withValues(alpha: 0.20) : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? GE.primary : Colors.white.withValues(alpha: 0.06),
            width: active ? 1.2 : 0.6,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: active ? GE.primary : GE.sub),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                color: active ? GE.primary : GE.sub,
                fontSize: 11, fontWeight: FontWeight.w700,
              )),
        ]),
      ),
    );
  }
}

class _NoMore extends StatelessWidget {
  const _NoMore();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 8),
      child: Center(
        child: Text('Комментариев больше нет',
            style: TextStyle(
                color: GE.muted, fontSize: 11, fontStyle: FontStyle.italic)),
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  final _Comment c;
  final String? myUsername;
  final VoidCallback onReply;
  final void Function(String emoji) onReact;
  final VoidCallback onToggleReplies;
  final List<_Comment>? replies;
  final bool repliesLoading;
  final void Function(_Comment reply, String emoji) onReactReply;
  final void Function(_Comment reply) onReplyToReply;
  const _CommentTile({
    required this.c,
    this.myUsername,
    required this.onReply,
    required this.onReact,
    required this.onToggleReplies,
    this.replies,
    this.repliesLoading = false,
    required this.onReactReply,
    required this.onReplyToReply,
  });

  @override
  Widget build(BuildContext context) {
    final expanded = replies != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CommentRow(
            c: c, myUsername: myUsername,
            onReply: onReply, onReact: onReact,
          ),
          if (c.repliesCount > 0)
            Padding(
              padding: const EdgeInsets.only(left: 44, top: 2),
              child: InkWell(
                onTap: onToggleReplies,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(expanded ? Icons.expand_less : Icons.expand_more,
                        size: 14, color: GE.primary),
                    const SizedBox(width: 4),
                    Text(
                      expanded
                          ? 'Скрыть ответы (${c.repliesCount})'
                          : 'Показать ответы (${c.repliesCount})',
                      style: TextStyle(
                          color: GE.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                  ]),
                ),
              ),
            ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (repliesLoading)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                            color: GE.primary, strokeWidth: 2),
                      ),
                    )
                  else if (replies!.isEmpty)
                    Text('Пусто',
                        style: TextStyle(color: GE.muted, fontSize: 11))
                  else
                    ...replies!.map((r) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: _CommentRow(
                            c: r,
                            myUsername: myUsername,
                            onReply: () => onReplyToReply(r),
                            onReact: (em) => onReactReply(r, em),
                            quoteTo: r.replyToUsername,
                            quoteText: r.replyToText,
                          ),
                        )),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CommentRow extends StatelessWidget {
  final _Comment c;
  final String? myUsername;
  final VoidCallback onReply;
  final void Function(String emoji) onReact;
  final String? quoteTo;
  final String? quoteText;
  const _CommentRow({
    required this.c,
    this.myUsername,
    required this.onReply,
    required this.onReact,
    this.quoteTo,
    this.quoteText,
  });

  static const _emoji = {
    'heart': '❤', 'fire': '🔥', 'laugh': '😂',
    'sad': '😢', 'clap': '👏', 'eyes': '👀',
  };

  String _ago(dynamic at) {
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

  Future<void> _openPalette(BuildContext context) async {
    HapticFeedback.mediumImpact();
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            radius: 999,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: _emoji.entries.map((e) => InkWell(
                customBorder: const CircleBorder(),
                onTap: () => Navigator.pop(ctx, e.key),
                child: Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c.yourEmoji == e.key
                        ? GE.primary.withValues(alpha: 0.30)
                        : Colors.transparent,
                  ),
                  alignment: Alignment.center,
                  child: Text(e.value, style: const TextStyle(fontSize: 24)),
                ),
              )).toList(),
            ),
          ),
        ),
      ),
    );
    if (selected != null) onReact(selected);
  }

  @override
  Widget build(BuildContext context) {
    final display = c.displayName.isNotEmpty ? c.displayName : c.username;
    final isMine = myUsername == c.username;
    final hasYour = c.yourEmoji != null;
    final emo = c.yourEmoji ?? 'heart';
    final total = c.counts.values.fold<int>(0, (a, b) => a + b);
    return InkWell(
      borderRadius: BorderRadius.circular(GE.radiusMd),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ProfileScreen(username: c.username),
      )),
      child: GlassCard(
        lite: true,
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
              ),
              alignment: Alignment.center,
              child: Text(
                display.isNotEmpty ? display[0].toUpperCase() : '?',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 12),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(display,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: GE.text,
                              fontWeight: FontWeight.w700,
                              fontSize: 13)),
                    ),
                    const SizedBox(width: 6),
                    Text('@${c.username}',
                        style: TextStyle(color: GE.sub, fontSize: 10)),
                    const Spacer(),
                    Text(_ago(c.createdAt),
                        style: TextStyle(color: GE.muted, fontSize: 10)),
                  ]),
                  if (quoteTo != null) Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(6, 4, 8, 4),
                      decoration: BoxDecoration(
                        color: GE.primary.withValues(alpha: 0.10),
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(6),
                          bottomRight: Radius.circular(6),
                        ),
                        border: Border(
                          left: BorderSide(color: GE.primary, width: 2),
                        ),
                      ),
                      child: Row(children: [
                        Icon(Icons.reply, size: 11, color: GE.primary),
                        const SizedBox(width: 4),
                        Text('@$quoteTo',
                            style: TextStyle(
                                color: GE.primary,
                                fontSize: 10,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            quoteText ?? '',
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: GE.sub, fontSize: 10),
                          ),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(c.text,
                      style: TextStyle(
                          color: GE.text, fontSize: 13, height: 1.35)),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(children: [
                      InkWell(
                        onTap: onReply,
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Text('Ответить',
                              style: TextStyle(color: GE.sub, fontSize: 11)),
                        ),
                      ),
                      if (isMine) Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text('это вы',
                            style: TextStyle(
                                color: GE.muted,
                                fontSize: 9,
                                fontStyle: FontStyle.italic)),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onLongPress: () => _openPalette(context),
                        child: InkWell(
                          onTap: () => onReact('heart'),
                          borderRadius: BorderRadius.circular(999),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              if (hasYour)
                                Text(_emoji[emo] ?? '❤',
                                    style: const TextStyle(fontSize: 14))
                              else
                                Icon(Icons.favorite_border, color: GE.sub, size: 14),
                              if (total > 0) Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Text('$total',
                                    style: TextStyle(
                                        color: hasYour ? GE.primary : GE.sub,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700)),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ]),
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

class _Comment {
  final int id;
  final int? parentId;
  final int? replyToId;
  final String username;
  final String displayName;
  final String text;
  final dynamic createdAt;
  Map<String, int> counts;
  String? yourEmoji;
  int repliesCount;
  final String? replyToUsername;
  final String? replyToText;
  _Comment({
    required this.id,
    required this.username,
    required this.displayName,
    required this.text,
    required this.createdAt,
    this.parentId,
    this.replyToId,
    Map<String, int>? counts,
    this.yourEmoji,
    this.repliesCount = 0,
    this.replyToUsername,
    this.replyToText,
  }) : counts = counts ?? <String, int>{};

  static _Comment fromMap(Map<String, dynamic> m) {
    final rx = (m['reactions'] is Map)
        ? Map<String, dynamic>.from(m['reactions']) : const <String, dynamic>{};
    final counts = <String, int>{};
    final rc = rx['counts'];
    if (rc is Map) {
      rc.forEach((k, v) {
        if (v is num) counts[k.toString()] = v.toInt();
      });
    }
    return _Comment(
      id: (m['id'] as num).toInt(),
      parentId: m['parent_id'] is num ? (m['parent_id'] as num).toInt() : null,
      replyToId: m['reply_to_id'] is num ? (m['reply_to_id'] as num).toInt() : null,
      username: (m['username'] as String?) ?? 'anon',
      displayName: (m['display_name'] as String?) ?? '',
      text: (m['text'] as String?) ?? '',
      createdAt: m['created_at'],
      counts: counts,
      yourEmoji: rx['your_emoji'] as String?,
      repliesCount: m['replies_count'] is num
          ? (m['replies_count'] as num).toInt() : 0,
      replyToUsername: m['reply_to_username'] as String?,
      replyToText: m['reply_to_text'] as String?,
    );
  }
}
