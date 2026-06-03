// WalletScreen — нативный кошелёк. Балансы Gost/Soul/Prem + транзакции +
// быстрые действия. NFT-витрина в отдельном табе.

import 'package:flutter/material.dart';
import '../theme.dart';
import '../services/api_client.dart';
import '../widgets/glass.dart';

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
      // GET /api/soc/wallet возвращает {gost, soul, prem}
      final w = await _api.socGet('/wallet');
      final tx = await _api.socGet('/wallet/tx', {'limit': 30});
      if (!mounted) return;
      setState(() {
        if (w is Map) {
          _gost = (w['gost'] as num?)?.toInt() ?? 0;
          _soul = (w['soul'] as num?) ?? 0;
          _prem = (w['prem'] as num?) ?? 0;
        }
        if (tx is Map && tx['items'] is List) {
          _txs = ((tx['items'] as List)
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m)))
              .toList();
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
            _balanceRow('Gost', '$_gost', '⚪', GE.muted, 'Базовая валюта — за активность'),
            const SizedBox(height: 8),
            _balanceRow('Soul', _fmt(_soul), '🔮', GE.primary, 'Премиум — за реальные деньги или эмиссию'),
            const SizedBox(height: 8),
            _balanceRow('Prem', _fmt(_prem), '👑', GE.yellow, 'Подписка — даёт привилегии'),
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

  Widget _balanceRow(String name, String value, String icon, Color color, String hint) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.2),
            ),
            alignment: Alignment.center,
            child: Text(icon, style: const TextStyle(fontSize: 22)),
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
            onTap: () {},
          ),
        ),
      ],
    );
  }

  void _todoTransfer() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Перевод'),
        content: const Text('Native-перевод придёт после MVP. Пока через веб /bank/.'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  Widget _txTile(Map<String, dynamic> t) {
    final amount = (t['amount'] as num?)?.toInt() ?? 0;
    final currency = (t['currency'] as String?) ?? 'gost';
    final reason = (t['reason'] as String?) ?? '';
    final at = t['created_at'];
    final positive = amount > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(positive ? Icons.arrow_downward : Icons.arrow_upward,
                color: positive ? GE.green : GE.red, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(reason.isEmpty ? '$currency' : reason,
                      style: TextStyle(color: GE.text, fontSize: 13)),
                  if (at != null)
                    Text(at.toString(),
                        style: TextStyle(color: GE.sub, fontSize: 11)),
                ],
              ),
            ),
            Text('${positive ? '+' : ''}$amount',
                style: TextStyle(
                    color: positive ? GE.green : GE.red,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ],
        ),
      ),
    );
  }

  String _fmt(num v) {
    if (v == v.toInt()) return v.toInt().toString();
    return v.toStringAsFixed(2);
  }
}
