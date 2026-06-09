// WrappedScreen — нативный «годовой итог» юзера (как Spotify Wrapped).
// Endpoint: GET /wrapped/{username} → {posts, miniska, comments, reactions_given,
// reactions_received, followers, following, top_reactions:[{emoji,count}],
// top_post:{id,preview,reactions}, gost_earned, bal:{gost,soul,prem}, nft_count,
// rank, rank_total, days_in, reputation, display_name, username}.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../services/api_client.dart';
import '../widgets/glass.dart';

class WrappedScreen extends StatefulWidget {
  final String username;
  const WrappedScreen({super.key, required this.username});
  @override
  State<WrappedScreen> createState() => _WrappedScreenState();
}

class _WrappedScreenState extends State<WrappedScreen> {
  final _api = ApiClient();
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await _api.socGet('/wrapped/${widget.username}');
      if (!mounted) return;
      if (r is Map) {
        setState(() {
          _data = Map<String, dynamic>.from(r);
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Не удалось загрузить';
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  int _intOf(dynamic v) => v is num ? v.toInt() : 0;

  Future<void> _share() async {
    final url = '${GE.baseUrl}/wrapped/${widget.username}';
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Ссылка скопирована')),
    );
  }

  Future<void> _openInBrowser() async {
    await launchUrl(
      Uri.parse('${GE.baseUrl}/wrapped/${widget.username}'),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: GlassAppBar(
        showBack: true,
        titleText: 'Wrapped',
        actions: [
          IconButton(
            icon: Icon(Icons.ios_share, color: GE.primary),
            onPressed: _share,
            tooltip: 'Скопировать ссылку',
          ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: GE.primary))
          : _error != null
              ? _errorState()
              : RefreshIndicator(
                  color: GE.primary,
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: _buildSlides(),
                  ),
                ),
    );
  }

  Widget _errorState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline, color: GE.red, size: 32),
            const SizedBox(height: 8),
            Text('Не загрузилось',
                style: TextStyle(color: GE.text, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(_error ?? '',
                textAlign: TextAlign.center,
                style: TextStyle(color: GE.sub, fontSize: 12)),
            const SizedBox(height: 12),
            GlassButton(
              label: 'Повторить', icon: Icons.refresh, primary: true,
              onTap: _load,
            ),
          ]),
        ),
      );

  List<Widget> _buildSlides() {
    final d = _data!;
    final displayName = (d['display_name'] as String?) ?? widget.username;
    final daysIn = _intOf(d['days_in']);
    final posts = _intOf(d['posts']);
    final miniska = _intOf(d['miniska']);
    final comments = _intOf(d['comments']);
    final reactionsGiven = _intOf(d['reactions_given']);
    final reactionsReceived = _intOf(d['reactions_received']);
    final followers = _intOf(d['followers']);
    final following = _intOf(d['following']);
    final reputation = _intOf(d['reputation']);
    final rank = _intOf(d['rank']);
    final rankTotal = _intOf(d['rank_total']);
    final gostEarned = _intOf(d['gost_earned']);
    final nftCount = _intOf(d['nft_count']);
    final bal = d['bal'] is Map ? Map<String, dynamic>.from(d['bal'] as Map) : <String, dynamic>{};
    final topReactions = (d['top_reactions'] is List) ? d['top_reactions'] as List : const [];
    final topPost = d['top_post'] is Map ? Map<String, dynamic>.from(d['top_post'] as Map) : null;

    return [
      // 0. Hero
      _heroCard(displayName, daysIn, rank, rankTotal, reputation),
      const SizedBox(height: 14),

      // 1. Творчество
      _sectionTitle('Что создал', Icons.brush),
      const SizedBox(height: 8),
      _statsGrid([
        ('Постов', posts, Icons.article, GE.primary),
        ('Минисок', miniska, Icons.movie_outlined, GE.primary2),
        ('Комментов', comments, Icons.mode_comment, GE.blue),
      ]),
      const SizedBox(height: 14),

      // 2. Реакции
      _sectionTitle('Реакции', Icons.favorite),
      const SizedBox(height: 8),
      _statsGrid([
        ('Получил', reactionsReceived, Icons.thumb_up, GE.red),
        ('Поставил', reactionsGiven, Icons.thumb_up_outlined, GE.sub),
      ]),
      if (topReactions.isNotEmpty) ...[
        const SizedBox(height: 8),
        _topReactionsCard(topReactions),
      ],
      const SizedBox(height: 14),

      // 3. Аудитория
      _sectionTitle('Аудитория', Icons.people_outline),
      const SizedBox(height: 8),
      _statsGrid([
        ('Подписчиков', followers, Icons.group, GE.primary),
        ('Подписок', following, Icons.person_add_alt_1, GE.primary2),
      ]),
      const SizedBox(height: 14),

      // 4. Топ пост
      if (topPost != null) ...[
        _sectionTitle('Звёздный пост', Icons.star),
        const SizedBox(height: 8),
        _topPostCard(topPost),
        const SizedBox(height: 14),
      ],

      // 5. Деньги
      _sectionTitle('Экономика', Icons.account_balance_wallet),
      const SizedBox(height: 8),
      _balanceCard(bal, gostEarned, nftCount),
      const SizedBox(height: 14),

      // 6. CTA — открыть в браузере (там PNG-картинка для шеринга)
      GlassButton(
        label: 'Открыть в браузере',
        icon: Icons.open_in_browser,
        primary: true,
        fullWidth: true,
        onTap: _openInBrowser,
      ),
      const SizedBox(height: 8),
      GlassButton(
        label: 'Скопировать ссылку',
        icon: Icons.link,
        fullWidth: true,
        onTap: _share,
      ),
      const SizedBox(height: 30),
    ];
  }

  Widget _heroCard(String name, int daysIn, int rank, int rankTotal, int rep) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            GE.primary.withValues(alpha: 0.30),
            GE.primary2.withValues(alpha: 0.20),
          ],
        ),
        borderRadius: BorderRadius.circular(GE.radiusLg),
        border: Border.all(color: GE.primary.withValues(alpha: 0.45)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [GE.primary, GE.primary2]),
            ),
            alignment: Alignment.center,
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w800, fontSize: 22),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name,
                    style: TextStyle(
                        color: GE.text,
                        fontSize: 22,
                        fontWeight: FontWeight.w800)),
                Text('@${widget.username}',
                    style: TextStyle(color: GE.sub, fontSize: 12)),
              ],
            ),
          ),
        ]),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _heroChip('${_daysWord(daysIn)} с нами', Icons.cake),
          if (rankTotal > 0)
            _heroChip('Ранг $rank из $rankTotal', Icons.leaderboard),
          _heroChip('Репутация $rep', Icons.verified),
        ]),
      ]),
    );
  }

  Widget _heroChip(String text, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.30),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: GE.primary),
          const SizedBox(width: 5),
          Text(text,
              style: TextStyle(
                color: GE.text,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              )),
        ]),
      );

  String _daysWord(int n) {
    final n10 = n % 10, n100 = n % 100;
    String w;
    if (n10 == 1 && n100 != 11) {
      w = 'день';
    } else if (n10 >= 2 && n10 <= 4 && (n100 < 10 || n100 >= 20)) {
      w = 'дня';
    } else {
      w = 'дней';
    }
    return '$n $w';
  }

  Widget _sectionTitle(String title, IconData icon) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 2),
        child: Row(children: [
          Icon(icon, size: 16, color: GE.primary),
          const SizedBox(width: 6),
          Text(title,
              style: TextStyle(
                color: GE.sub,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
              )),
        ]),
      );

  Widget _statsGrid(List<(String, int, IconData, Color)> items) {
    return Row(
      children: items.map((it) {
        final i = items.indexOf(it);
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(left: i == 0 ? 0 : 6),
            child: _statTile(it.$1, it.$2, it.$3, it.$4),
          ),
        );
      }).toList(),
    );
  }

  Widget _statTile(String label, int value, IconData icon, Color tint) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      child: Column(children: [
        Icon(icon, color: tint, size: 18),
        const SizedBox(height: 6),
        Text('$value',
            style: TextStyle(
                color: GE.text,
                fontSize: 20,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(color: GE.sub, fontSize: 10)),
      ]),
    );
  }

  Widget _topReactionsCard(List items) {
    return GlassCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Любимые эмодзи',
              style: TextStyle(
                  color: GE.sub, fontSize: 11, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: items.take(3).map<Widget>((raw) {
            if (raw is! Map) return const SizedBox.shrink();
            final r = Map<String, dynamic>.from(raw);
            final em = (r['emoji'] as String?) ?? '?';
            final cnt = _intOf(r['count']);
            return Column(children: [
              Text(_glyph(em), style: const TextStyle(fontSize: 28)),
              const SizedBox(height: 4),
              Text('$cnt',
                  style: TextStyle(
                      color: GE.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ]);
          }).toList()),
        ],
      ),
    );
  }

  Widget _topPostCard(Map post) {
    final preview = (post['preview'] as String?) ?? '';
    final reactions = _intOf(post['reactions']);
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.local_fire_department, color: GE.red, size: 18),
            const SizedBox(width: 6),
            Text('$reactions реакций',
                style: TextStyle(
                    color: GE.red,
                    fontSize: 12,
                    fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 8),
          Text(preview.isNotEmpty ? preview : '(пост без текста)',
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: GE.text, fontSize: 13, height: 1.4)),
        ],
      ),
    );
  }

  Widget _balanceCard(Map bal, int earned, int nftCount) {
    final gost = _intOf(bal['gost']);
    final soul = _intOf(bal['soul']);
    final prem = _intOf(bal['prem']);
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(children: [
        Row(children: [
          _coin('Gost', gost, GE.blue),
          _coin('Soul', soul, GE.primary),
          _coin('Prem', prem, GE.yellow),
        ]),
        const Divider(height: 18),
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Заработал', style: TextStyle(color: GE.sub, fontSize: 10)),
              const SizedBox(height: 2),
              Row(children: [
                Icon(Icons.savings, color: GE.blue, size: 14),
                const SizedBox(width: 4),
                Text('$earned Gost',
                    style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w800)),
              ]),
            ]),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('NFT в коллекции', style: TextStyle(color: GE.sub, fontSize: 10)),
              const SizedBox(height: 2),
              Row(children: [
                Icon(Icons.diamond_outlined, color: GE.primary, size: 14),
                const SizedBox(width: 4),
                Text('$nftCount',
                    style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w800)),
              ]),
            ]),
          ),
        ]),
      ]),
    );
  }

  Widget _coin(String label, int value, Color color) => Expanded(
        child: Column(children: [
          Text('$value',
              style: TextStyle(
                color: color,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              )),
          Text(label,
              style: TextStyle(color: GE.sub, fontSize: 10)),
        ]),
      );

  static const _glyphMap = {
    'heart': '❤', 'fire': '🔥', 'laugh': '😂',
    'sad': '😢', 'clap': '👏', 'eyes': '👀',
  };
  String _glyph(String key) => _glyphMap[key] ?? key;
}
