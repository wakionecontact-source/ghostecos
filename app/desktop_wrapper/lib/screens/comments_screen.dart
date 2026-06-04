// CommentsScreen — комменты под постом, нативный экран.
// Endpoints: GET /com/get/{post_id}, POST /com/{post_id}
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
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  bool _sending = false;
  bool _hasMore = true;
  String? _myUsername;

  @override
  void initState() {
    super.initState();
    _init();
    _scroll.addListener(() {
      if (!_loading &&
          _hasMore &&
          _scroll.position.pixels > _scroll.position.maxScrollExtent - 200) {
        _loadMore();
      }
    });
  }

  Future<void> _init() async {
    _myUsername = await AuthService.username();
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _items = [];
      _hasMore = true;
    });
    await _loadMore(initial: true);
  }

  Future<void> _loadMore({bool initial = false}) async {
    try {
      final r = await _api.socGet('/com/get/${widget.postId}',
          {'offset': initial ? 0 : _items.length});
      if (!mounted) return;
      if (r is Map) {
        final list = (r['comments'] as List?) ?? const [];
        setState(() {
          _items.addAll(list
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m)));
          _hasMore = (r['has_more'] as bool?) ?? false;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final t = _ctrl.text.trim();
    if (t.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _api.socPost('/com/${widget.postId}', {'text': t});
      _ctrl.clear();
      await _load();
      HapticFeedback.lightImpact();
    } catch (e) {
      _snack('Не отправилось: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
                            Text('Комментариев пока нет',
                                style: TextStyle(color: GE.sub, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text('Будь первым',
                                style: TextStyle(color: GE.muted, fontSize: 11)),
                          ]),
                        ),
                      )
                    : ListView.separated(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                        itemCount: _items.length + (_hasMore ? 1 : 0),
                        separatorBuilder: (_, _) => const SizedBox(height: 4),
                        itemBuilder: (_, i) {
                          if (i == _items.length) {
                            return Padding(
                              padding: const EdgeInsets.all(16),
                              child: Center(
                                child: CircularProgressIndicator(
                                    color: GE.primary, strokeWidth: 2),
                              ),
                            );
                          }
                          return _CommentTile(c: _items[i], myUsername: _myUsername);
                        },
                      ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: GlassCard(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                radius: GE.radiusLg,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ctrl,
                        minLines: 1,
                        maxLines: 4,
                        maxLength: 500,
                        style: TextStyle(color: GE.text, fontSize: 14),
                        cursorColor: GE.primary,
                        decoration: InputDecoration(
                          hintText: 'Комментарий',
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
                          gradient:
                              LinearGradient(colors: [GE.primary2, GE.primary]),
                        ),
                        alignment: Alignment.center,
                        child: _sending
                            ? const SizedBox(
                                width: 14, height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.send,
                                color: Colors.white, size: 16),
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
}

class _CommentTile extends StatelessWidget {
  final Map<String, dynamic> c;
  final String? myUsername;
  const _CommentTile({required this.c, this.myUsername});

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

  @override
  Widget build(BuildContext context) {
    final username = (c['username'] as String?) ?? '?';
    final display = (c['display_name'] as String?) ?? username;
    final text = (c['text'] as String?) ?? '';
    final isMine = myUsername == username;
    return InkWell(
      borderRadius: BorderRadius.circular(GE.radiusMd),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ProfileScreen(username: username),
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
                gradient: LinearGradient(
                    colors: [GE.primary2, GE.primary]),
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
                    Text('@$username',
                        style: TextStyle(color: GE.sub, fontSize: 10)),
                    const Spacer(),
                    Text(_ago(c['created_at']),
                        style: TextStyle(color: GE.muted, fontSize: 10)),
                  ]),
                  const SizedBox(height: 3),
                  Text(text,
                      style: TextStyle(
                          color: GE.text, fontSize: 13, height: 1.35)),
                  if (isMine)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('это вы',
                          style: TextStyle(
                              color: GE.muted,
                              fontSize: 9,
                              fontStyle: FontStyle.italic)),
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
