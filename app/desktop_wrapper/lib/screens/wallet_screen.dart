// WalletScreen — нативный кошелёк. Балансы Gost/Soul/Prem + транзакции +
// быстрые действия. NFT-витрина в отдельном табе.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../services/api_client.dart';
import '../widgets/glass.dart';
import 'nft_screen.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});
  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  final _api = ApiClient();
  int _gost = 0;
  num _soul = 0;
  num _prem = 0;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _txs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // GET /api/soc/wallet → {balance: {gost,soul,prem}, daily_reward, next_daily_in}
      // GET /api/soc/wallet/tx → {transactions: [{delta, currency, source, ...}], has_more}
      final w = await _api.socGet('/wallet');
      final tx = await _api.socGet('/wallet/tx');
      if (!mounted) return;
      setState(() {
        if (w is Map) {
          final bal = w['balance'];
          if (bal is Map) {
            _gost = (bal['gost'] as num?)?.toInt() ?? 0;
            _soul = (bal['soul'] as num?) ?? 0;
            _prem = (bal['prem'] as num?) ?? 0;
          }
        }
        if (tx is Map) {
          final list = tx['transactions'] ?? tx['items'] ?? const [];
          if (list is List) {
            _txs = list
                .whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList();
          }
        } else if (tx is List) {
          _txs = tx.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
        }
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
    return RefreshIndicator(
      color: GE.primary,
      onRefresh: () async => _load(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
        children: [
          Row(
            children: [
              Icon(Icons.account_balance_wallet_outlined, color: GE.primary, size: 22),
              const SizedBox(width: 8),
              Text('Банк',
                  style: TextStyle(
                      color: GE.text, fontSize: 20, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 12),
          if (_loading)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator(color: GE.primary)),
            )
          else if (_error != null)
            GlassCard(
              child: Column(
                children: [
                  Icon(Icons.error_outline, color: GE.red),
                  const SizedBox(height: 8),
                  Text('Не загрузилось: $_error', style: TextStyle(color: GE.sub)),
                ],
              ),
            )
          else ...[
            _balanceRow('Gost', '$_gost', 'G', Icons.toll, GE.blue,
                'Базовая валюта — за активность'),
            const SizedBox(height: 8),
            _balanceRow('Soul', _fmt(_soul), 'S', Icons.auto_awesome, GE.primary,
                'Премиум — за реальные деньги или эмиссию'),
            const SizedBox(height: 8),
            _balanceRow('Prem', _fmt(_prem), 'P', Icons.workspace_premium, GE.yellow,
                'Подписка — даёт привилегии'),
            const SizedBox(height: 16),
            _actionsBar(),
            const SizedBox(height: 16),
            _sectionTitle('Транзакции'),
            if (_txs.isEmpty)
              GlassCard(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Icon(Icons.history, color: GE.sub),
                    const SizedBox(height: 6),
                    Text('Пока нет операций', style: TextStyle(color: GE.sub)),
                  ],
                ),
              )
            else
              for (final t in _txs) _txTile(t),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                color: GE.sub, fontSize: 11, fontWeight: FontWeight.w700,
                letterSpacing: 0.5)),
      );

  Widget _balanceRow(String name, String value, String letter, IconData icon,
      Color color, String hint) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [color.withValues(alpha: 0.55), color.withValues(alpha: 0.85)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: Border.all(color: color.withValues(alpha: 0.6), width: 1),
            ),
            alignment: Alignment.center,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon, color: Colors.white.withValues(alpha: 0.35), size: 30),
                Text(letter,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5)),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: TextStyle(
                        color: GE.text, fontWeight: FontWeight.w700, fontSize: 14)),
                Text(hint,
                    style: TextStyle(color: GE.sub, fontSize: 11),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Text(value,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w900, fontSize: 22,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }

  Widget _actionsBar() {
    return Row(
      children: [
        Expanded(
          child: GlassButton(
            label: 'Перевод',
            icon: Icons.send,
            onTap: _todoTransfer,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: GlassButton(
            label: 'NFT',
            icon: Icons.diamond_outlined,
            primary: true,
            onTap: _openNft,
          ),
        ),
      ],
    );
  }

  void _openNft() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const NftScreen(),
    ));
  }

  void _todoTransfer() {
    // Open web /bank/ для перевода — там полный поток.
    launchUrl(Uri.parse('${GE.baseUrl}/bank/'),
        mode: LaunchMode.externalApplication);
  }

  static const _sourceLabel = {
    'daily': 'Ежедневный бонус',
    'register': 'За регистрацию',
    'post': 'За пост',
    'react': 'Реакция',
    'comment': 'Комментарий',
    'follow': 'Подписка',
    'transfer': 'Перевод',
    'transfer_in': 'Перевод входящий',
    'transfer_out': 'Перевод исходящий',
    'nft_buy': 'Покупка NFT',
    'nft_sell': 'Продажа NFT',
    'username': 'Кастомный @username',
    'soul_emit': 'Эмиссия Soul',
    'overwatch': 'Overwatch',
    'mint': 'Минт NFT',
    'admin': 'Админ-корректировка',
  };

  Color _currencyColor(String c) {
    switch (c) {
      case 'soul': return GE.primary;
      case 'prem': return GE.yellow;
      default: return GE.blue;
    }
  }

  Widget _txTile(Map<String, dynamic> t) {
    final amount = ((t['delta'] as num?) ?? (t['amount'] as num?) ?? 0).toInt();
    final currency = (t['currency'] as String?) ?? 'gost';
    final rawSource = (t['source'] as String?) ?? (t['reason'] as String?) ?? '';
    final label = _sourceLabel[rawSource] ?? (rawSource.isEmpty ? 'Операция' : rawSource);
    final at = t['created_at'];
    final positive = amount > 0;
    final curColor = _currencyColor(currency);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: GlassCard(
        lite: true,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: (positive ? GE.green : GE.red).withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(positive ? Icons.arrow_downward : Icons.arrow_upward,
                  color: positive ? GE.green : GE.red, size: 16),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: GE.text, fontSize: 13, fontWeight: FontWeight.w500)),
                  if (at != null)
                    Text(_fmtAt(at),
                        style: TextStyle(color: GE.sub, fontSize: 11)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${positive ? '+' : ''}$amount',
                    style: TextStyle(
                        color: positive ? GE.green : GE.red,
                        fontWeight: FontWeight.w800, fontSize: 15,
                        fontFeatures: const [FontFeature.tabularFigures()])),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: curColor.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(currency.toUpperCase(),
                      style: TextStyle(
                          color: curColor, fontSize: 9, fontWeight: FontWeight.w800,
                          letterSpacing: 0.5)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmtAt(dynamic at) {
    if (at == null) return '';
    try {
      final dt = (at is int)
          ? DateTime.fromMillisecondsSinceEpoch(at * 1000)
          : DateTime.parse(at.toString()).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 1) return 'только что';
      if (diff.inMinutes < 60) return '${diff.inMinutes} мин назад';
      if (diff.inHours < 24) return '${diff.inHours} ч назад';
      if (diff.inDays < 7) return '${diff.inDays} д назад';
      return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
    } catch (_) { return ''; }
  }

  String _fmt(num v) {
    if (v == v.toInt()) return v.toInt().toString();
    return v.toStringAsFixed(2);
  }
}
