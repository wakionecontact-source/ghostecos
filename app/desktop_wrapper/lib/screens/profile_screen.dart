// ProfileScreen — полный профиль юзера: шапка с аватаром / именем /
// статусом / репутацией, статы (постов/подписчиков/подписок/лайков),
// кнопки follow + написать, лента собственных постов с подгрузкой.
//
// API: /prof/{username} → инфо + первые 15 постов
//      /user/{username}/feed_combined → посты + репосты в хронологии
//      /prof/{username}/posts?offset=N → пагинация
//      POST /follow/{username} / DELETE /follow/{username}
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../widgets/glass.dart';
import 'chat_screen.dart';

class ProfileScreen extends StatefulWidget {
  final String username;
  const ProfileScreen({super.key, required this.username});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _api = ApiClient();
  final _scroll = ScrollController();
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>> _items = []; // posts + reposts
  bool _loadingMore = false;
  bool _exhausted = false;
  String? _myUsername;
  bool _followBusy = false;

  bool get _isMe => (_profile?['is_me'] as bool?) == true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  Future<void> _load() async {
    _myUsername = await AuthService.username();
    try {
      final p = await _api.socGet('/prof/${widget.username}');
      if (!mounted) return;
      List<Map<String, dynamic>> items = [];
      // Подтянем combined-ленту с репостами параллельно
      try {
        final feed = await _api.socGet('/user/${widget.username}/feed_combined',
            {'limit': 40});
        if (feed is List) {
          items = feed
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
        }
      } catch (_) {
        // Fallback на posts из /prof
        if (p is Map && p['posts'] is List) {
          items = (p['posts'] as List)
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
        }
      }
      setState(() {
        _profile = Map<String, dynamic>.from(p as Map);
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

  void _onScroll() {
    if (_loadingMore || _exhausted) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _exhausted) return;
    _loadingMore = true;
    try {
      final r = await _api.socGet(
          '/prof/${widget.username}/posts', {'offset': _items.length});
      if (r is List) {
        if (r.isEmpty) {
          _exhausted = true;
        } else {
          final more = r
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
          setState(() => _items = [..._items, ...more]);
        }
      }
    } catch (_) {} finally {
      _loadingMore = false;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _toggleFollow() async {
    if (_followBusy || _profile == null) return;
    setState(() => _followBusy = true);
    final wasFollowing = (_profile!['am_following'] as bool?) ?? false;
    try {
      if (wasFollowing) {
        await _api.socDelete('/follow/${widget.username}');
      } else {
        await _api.socPost('/follow/${widget.username}');
      }
      setState(() {
        _profile!['am_following'] = !wasFollowing;
        _profile!['followers_count'] =
            ((_profile!['followers_count'] as num?) ?? 0).toInt() +
                (wasFollowing ? -1 : 1);
      });
      HapticFeedback.selectionClick();
    } catch (e) {
      _snack('Не вышло: $e');
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: GlassAppBar(
        showBack: true,
        titleText: _profile?['display_name'] as String? ?? widget.username,
      ),
      body: RefreshIndicator(
        color: GE.primary,
        onRefresh: () async {
          setState(() => _loading = true);
          await _load();
        },
        child: _loading
            ? Center(child: CircularProgressIndicator(color: GE.primary))
            : _error != null
                ? _errorView()
                : _body(),
      ),
    );
  }

  Widget _errorView() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 80),
        Center(
          child: GlassCard(
            lite: true,
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.error_outline, color: GE.red, size: 32),
              const SizedBox(height: 8),
              Text('Не загрузился профиль',
                  style: TextStyle(color: GE.text, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GE.sub, fontSize: 11)),
              const SizedBox(height: 12),
              GlassButton(
                label: 'Повторить',
                icon: Icons.refresh,
                primary: true,
                onTap: _load,
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _body() {
    final p = _profile!;
    final displayName = (p['display_name'] as String?) ?? widget.username;
    final repScore = (p['reputation_score'] as num?)?.toInt() ?? 100;
    final repBand = (p['reputation_band'] as String?) ?? 'mid';
    final dailyStatus = p['daily_status'] as String?;
    final dailyMood = p['daily_status_mood'] as String?;
    final eternal = (p['daily_status_eternal'] as bool?) ?? false;
    final amFollowing = (p['am_following'] as bool?) ?? false;
    final posts = (p['posts_count'] as num?)?.toInt() ?? 0;
    final followers = (p['followers_count'] as num?)?.toInt() ?? 0;
    final following = (p['following_count'] as num?)?.toInt() ?? 0;
    final likes = (p['likes_received'] as num?)?.toInt() ?? 0;

    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
      children: [
        // Шапка
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(children: [
                Container(
                  width: 64, height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w800, fontSize: 28),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(displayName,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: GE.text,
                              fontSize: 20,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text('@${widget.username}',
                          style: TextStyle(color: GE.sub, fontSize: 13)),
                      const SizedBox(height: 4),
                      _reputationBadge(repScore, repBand),
                    ],
                  ),
                ),
              ]),
              if (dailyStatus != null && dailyStatus.isNotEmpty) ...[
                const SizedBox(height: 12),
                _statusBadge(dailyStatus, dailyMood, eternal),
              ],
              const SizedBox(height: 16),
              if (!_isMe) _actionsRow(amFollowing),
              if (_isMe)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: GE.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('Это ваш профиль',
                      style: TextStyle(
                          color: GE.primary, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Статы
        Row(children: [
          Expanded(child: _statCard('Постов', '$posts', Icons.article_outlined)),
          const SizedBox(width: 8),
          Expanded(child: _statCard('Подписчики', '$followers', Icons.people_alt_outlined)),
          const SizedBox(width: 8),
          Expanded(child: _statCard('Подписки', '$following', Icons.person_add_outlined)),
          const SizedBox(width: 8),
          Expanded(child: _statCard('Лайки', '$likes', Icons.favorite_border)),
        ]),
        const SizedBox(height: 16),
        _sectionTitle('Посты'),
        if (_items.isEmpty)
          GlassCard(
            lite: true,
            padding: const EdgeInsets.all(20),
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.article_outlined, color: GE.sub, size: 32),
                const SizedBox(height: 6),
                Text('Постов пока нет',
                    style: TextStyle(color: GE.sub, fontSize: 13)),
              ]),
            ),
          )
        else
          for (final it in _items) _ProfilePostTile(item: it, myUsername: _myUsername),
        if (_loadingMore)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
                child: CircularProgressIndicator(color: GE.primary, strokeWidth: 2)),
          ),
      ],
    );
  }

  Widget _statusBadge(String text, String? mood, bool eternal) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: GE.glassFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: eternal ? GE.primary : GE.glassBorder,
            width: eternal ? 1.2 : 0.6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (mood != null && mood.isNotEmpty) ...[
          Text(mood, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
        ] else
          Icon(eternal ? Icons.all_inclusive : Icons.mode_comment_outlined,
              size: 13, color: GE.primary),
        const SizedBox(width: 2),
        Flexible(
          child: Text(text,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: GE.text, fontSize: 12)),
        ),
      ]),
    );
  }

  Widget _reputationBadge(int score, String band) {
    final color = band == 'good' ? GE.green : (band == 'low' ? GE.red : GE.yellow);
    final label = band == 'good'
        ? 'Хорошая'
        : (band == 'low' ? 'Низкая' : 'Средняя');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 0.6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.shield_outlined, size: 11, color: color),
        const SizedBox(width: 3),
        Text('Репутация $label · $score',
            style: TextStyle(
                color: color, fontSize: 10, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _actionsRow(bool following) {
    return Row(children: [
      Expanded(
        child: GlassButton(
          label: following ? 'Отписаться' : 'Подписаться',
          icon: following ? Icons.person_remove_outlined : Icons.person_add_outlined,
          primary: !following,
          loading: _followBusy,
          onTap: _toggleFollow,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: GlassButton(
          label: 'Написать',
          icon: Icons.chat_bubble_outline,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ChatScreen(
              peer: widget.username,
              displayName: (_profile!['display_name'] as String?) ?? widget.username,
            ),
          )),
        ),
      ),
    ]);
  }

  Widget _statCard(String label, String value, IconData icon) {
    return GlassCard(
      lite: true,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      child: Column(children: [
        Icon(icon, color: GE.primary, size: 16),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                color: GE.text,
                fontSize: 16,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(height: 2),
        Text(label,
            textAlign: TextAlign.center,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: GE.sub, fontSize: 10)),
      ]),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                color: GE.sub,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5)),
      );
}

// ────────────────────────────────────────────────────────────────────────
/// Упрощённая карточка поста для профиля — текст, медиа, репост-метка, статы.
/// Для полной интерактивности (реакции/меню/share) — открывает пост в браузере.
class _ProfilePostTile extends StatelessWidget {
  final Map<String, dynamic> item;
  final String? myUsername;
  const _ProfilePostTile({required this.item, this.myUsername});

  @override
  Widget build(BuildContext context) {
    final isRepost = item['kind'] == 'repost' || item['is_repost'] == true;
    final content = (item['content'] as String?) ?? '';
    final isNsfw = item['is_nsfw'] == true || item['is_nsfw'] == 1;
    final commentsCount = (item['comments_count'] as num?)?.toInt() ?? 0;
    final reactions = item['reactions'];
    int reactionsTotal = 0;
    if (reactions is Map) {
      final total = reactions['total'];
      if (total is num) {
        reactionsTotal = total.toInt();
      } else {
        for (final v in reactions.values) {
          if (v is num) reactionsTotal += v.toInt();
        }
      }
    }
    final mediaList = (item['media'] is List) ? item['media'] as List : const [];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: GlassCard(
        lite: true,
        padding: const EdgeInsets.all(12),
        onTap: () => launchUrl(Uri.parse('${GE.baseUrl}/p/${item['id']}'),
            mode: LaunchMode.externalApplication),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isRepost)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(children: [
                  Icon(Icons.repeat, size: 12, color: GE.sub),
                  const SizedBox(width: 4),
                  Text('репост',
                      style: TextStyle(
                          color: GE.sub, fontSize: 11, fontWeight: FontWeight.w600)),
                ]),
              ),
            Row(children: [
              if (isNsfw)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: GE.red.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text('18+',
                      style: TextStyle(
                          color: GE.red, fontSize: 9, fontWeight: FontWeight.w800)),
                ),
              const Spacer(),
              Text(_ago(item['created_at']),
                  style: TextStyle(color: GE.sub, fontSize: 11)),
            ]),
            if (isNsfw) ...[
              const SizedBox(height: 8),
              Container(
                height: 90,
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: GE.red.withValues(alpha: 0.3)),
                ),
                alignment: Alignment.center,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.visibility_off, color: GE.red, size: 16),
                  const SizedBox(width: 8),
                  Text('18+ — открыть в браузере',
                      style: TextStyle(color: GE.text, fontSize: 12)),
                ]),
              ),
            ] else ...[
              if (content.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(content,
                    maxLines: 6, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: GE.text, fontSize: 14, height: 1.35)),
              ],
              if (mediaList.isNotEmpty) ...[
                const SizedBox(height: 6),
                _MediaPreview(media: mediaList),
              ],
            ],
            const SizedBox(height: 8),
            Row(children: [
              if (reactionsTotal > 0) ...[
                Icon(Icons.favorite, size: 12, color: GE.red),
                const SizedBox(width: 3),
                Text('$reactionsTotal',
                    style: TextStyle(color: GE.sub, fontSize: 11)),
                const SizedBox(width: 12),
              ],
              if (commentsCount > 0) ...[
                Icon(Icons.mode_comment_outlined, size: 12, color: GE.sub),
                const SizedBox(width: 3),
                Text('$commentsCount',
                    style: TextStyle(color: GE.sub, fontSize: 11)),
              ],
              const Spacer(),
              Icon(Icons.open_in_new, size: 12, color: GE.sub),
            ]),
          ],
        ),
      ),
    );
  }

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
      return '${dt.toLocal().day}.${dt.toLocal().month.toString().padLeft(2, '0')}';
    } catch (_) { return ''; }
  }
}

class _MediaPreview extends StatelessWidget {
  final List media;
  const _MediaPreview({required this.media});

  String _abs(String u) => u.startsWith('http') ? u : '${GE.baseUrl}$u';

  @override
  Widget build(BuildContext context) {
    final imgs = media
        .whereType<Map>()
        .where((m) => m['type'] == 'image' && m['url'] is String)
        .map((m) => m['url'] as String)
        .toList();
    if (imgs.isEmpty) {
      // Видео/аудио — иконка-заглушка
      return Container(
        height: 70,
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.play_circle_outline, color: GE.sub, size: 28),
      );
    }
    if (imgs.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(_abs(imgs[0]),
            height: 200, fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(
                  height: 80,
                  color: Colors.black26,
                  alignment: Alignment.center,
                  child: Icon(Icons.broken_image, color: GE.sub),
                )),
      );
    }
    // Grid 2-3+
    final visible = imgs.take(4).toList();
    return SizedBox(
      height: 120,
      child: Row(
        children: [
          for (var i = 0; i < visible.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(_abs(visible[i]),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(color: Colors.black26)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
