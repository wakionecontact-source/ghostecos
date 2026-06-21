// NftScreen — нативная NFT-витрина. 3 таба: Каталог / Маркет / Моя коллекция.
// Endpoints:
//   GET  /nft/catalog                → {catalog:[{id,slug,name,description,rarity,
//                                       max_supply,minted,listed,floor_gost,floor_soul,
//                                       start_price_gost,image_kind,image_data,bg_color,
//                                       creator:{username,display_name,is_official}}]}
//   GET  /nft/my                     → {nfts:[...]}
//   GET  /nft/listings?slug=&sort=   → {listings:[...], has_more}
//   POST /nft/buy/{nft_id}           → купить с маркета
//   POST /nft/list {nft_id,price_soul} → выставить на продажу
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../services/api_client.dart';
import '../widgets/glass.dart';

class NftScreen extends StatefulWidget {
  const NftScreen({super.key});
  @override
  State<NftScreen> createState() => _NftScreenState();
}

class _NftScreenState extends State<NftScreen> with TickerProviderStateMixin {
  late final TabController _tab;
  final _api = ApiClient();
  List<Map<String, dynamic>> _catalog = [];
  List<Map<String, dynamic>> _myNfts = [];
  List<Map<String, dynamic>> _listings = [];
  bool _loadingCatalog = true, _loadingMy = true, _loadingListings = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _loadAll();
  }

  Future<void> _loadAll() async {
    _loadCatalog();
    _loadListings();
    _loadMy();
  }

  Future<void> _loadCatalog() async {
    setState(() => _loadingCatalog = true);
    try {
      final r = await _api.socGet('/nft/catalog');
      if (!mounted) return;
      if (r is Map && r['catalog'] is List) {
        setState(() {
          _catalog = (r['catalog'] as List)
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m)).toList();
        });
      }
    } catch (e) { _error = '$e'; }
    finally { if (mounted) setState(() => _loadingCatalog = false); }
  }

  Future<void> _loadMy() async {
    setState(() => _loadingMy = true);
    try {
      final r = await _api.socGet('/nft/my');
      if (!mounted) return;
      if (r is Map && r['nfts'] is List) {
        setState(() {
          _myNfts = (r['nfts'] as List).whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m)).toList();
        });
      }
    } catch (_) {}
    finally { if (mounted) setState(() => _loadingMy = false); }
  }

  Future<void> _loadListings() async {
    setState(() => _loadingListings = true);
    try {
      final r = await _api.socGet('/nft/listings', {'sort': 'price_asc'});
      if (!mounted) return;
      if (r is Map && r['listings'] is List) {
        setState(() {
          _listings = (r['listings'] as List).whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m)).toList();
        });
      }
    } catch (_) {}
    finally { if (mounted) setState(() => _loadingListings = false); }
  }

  Future<void> _buy(int nftId, int price, String currency) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: Text('Купить NFT?', style: TextStyle(color: GE.text)),
        content: Text('Цена: $price $currency',
            style: TextStyle(color: GE.sub, fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: Text('Купить', style: TextStyle(color: GE.primary, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.socPost('/nft/buy/$nftId', {});
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Куплено')),
      );
      _loadAll();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось купить: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: GlassAppBar(
        showBack: true,
        titleText: 'NFT',
        actions: [
          IconButton(
            icon: Icon(Icons.open_in_browser, color: GE.primary),
            tooltip: 'Открыть полный банк в браузере',
            onPressed: () => launchUrl(
                Uri.parse('${GE.baseUrl}/bank/'),
                mode: LaunchMode.externalApplication),
          ),
        ],
      ),
      body: Column(children: [
        Container(
          color: Colors.transparent,
          child: TabBar(
            controller: _tab,
            indicatorColor: GE.primary,
            labelColor: GE.primary,
            unselectedLabelColor: GE.sub,
            indicatorWeight: 2.5,
            labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
            tabs: const [
              Tab(text: 'КАТАЛОГ'),
              Tab(text: 'МАРКЕТ'),
              Tab(text: 'МОЯ'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              _grid(_loadingCatalog, _catalog, _catalogCard),
              _grid(_loadingListings, _listings, _listingCard),
              _grid(_loadingMy, _myNfts, _myCard),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _grid(bool loading, List<Map<String, dynamic>> items, Widget Function(Map<String, dynamic>) builder) {
    if (loading) return Center(child: CircularProgressIndicator(color: GE.primary));
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.diamond_outlined, color: GE.sub, size: 32),
            const SizedBox(height: 8),
            Text('Пусто', style: TextStyle(color: GE.sub, fontSize: 13)),
          ]),
        ),
      );
    }
    return RefreshIndicator(
      color: GE.primary,
      onRefresh: _loadAll,
      child: GridView.builder(
        padding: const EdgeInsets.all(10),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 0.75,
        ),
        itemCount: items.length,
        itemBuilder: (_, i) => builder(items[i]),
      ),
    );
  }

  Widget _artBox(Map<String, dynamic> nft) {
    final bg = _parseColor(nft['bg_color'] as String? ?? '#a855f7');
    final name = (nft['name'] as String?) ?? '?';
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [bg.withValues(alpha: 0.85), bg.withValues(alpha: 0.55)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          name,
          textAlign: TextAlign.center,
          maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }

  Color _parseColor(String hex) {
    try {
      final h = hex.replaceFirst('#', '');
      return Color(int.parse('ff$h', radix: 16));
    } catch (_) { return GE.primary; }
  }

  Widget _catalogCard(Map<String, dynamic> it) {
    final name = (it['name'] as String?) ?? '?';
    final rarity = (it['rarity'] as String?) ?? '';
    final minted = it['minted'] is num ? (it['minted'] as num).toInt() : 0;
    final maxSupply = it['max_supply'] is num ? (it['max_supply'] as num).toInt() : 0;
    final floorGost = it['floor_gost'];
    final start = it['start_price_gost'];
    return GlassCard(
      lite: true,
      padding: const EdgeInsets.all(8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: _artBox(it)),
        const SizedBox(height: 6),
        Text(name,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: GE.text, fontSize: 13, fontWeight: FontWeight.w700)),
        Text('$minted / $maxSupply · $rarity',
            style: TextStyle(color: GE.sub, fontSize: 10)),
        const SizedBox(height: 2),
        Row(children: [
          Icon(Icons.savings, size: 11, color: GE.blue),
          const SizedBox(width: 3),
          Text(
            floorGost != null ? '${floorGost is num ? floorGost.toInt() : floorGost} Gost' : 'от $start G',
            style: TextStyle(color: GE.blue, fontSize: 11, fontWeight: FontWeight.w800),
          ),
        ]),
      ]),
    );
  }

  Widget _listingCard(Map<String, dynamic> it) {
    final price = it['price_soul'];
    final currency = (it['currency'] as String?) ?? 'gost';
    final nftId = it['nft_id'] is num ? (it['nft_id'] as num).toInt() : 0;
    final name = (it['name'] as String?) ?? '?';
    return GlassCard(
      lite: true,
      padding: const EdgeInsets.all(8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: _artBox(it)),
        const SizedBox(height: 6),
        Text(name,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: GE.text, fontSize: 13, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        InkWell(
          onTap: nftId > 0 && price is num
              ? () => _buy(nftId, price.toInt(), currency)
              : null,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              '$price $currency',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _myCard(Map<String, dynamic> it) {
    final name = (it['name'] as String?) ?? '?';
    final isListed = it['is_listed'] == true ||
        (it['listing'] != null && it['listing'] is Map);
    return GlassCard(
      lite: true,
      padding: const EdgeInsets.all(8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: _artBox(it)),
        const SizedBox(height: 6),
        Text(name,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: GE.text, fontSize: 13, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(isListed ? 'на маркете' : 'в коллекции',
            style: TextStyle(
                color: isListed ? GE.yellow : GE.sub,
                fontSize: 10,
                fontWeight: isListed ? FontWeight.w700 : FontWeight.normal)),
      ]),
    );
  }

  @override
  void dispose() { _tab.dispose(); super.dispose(); }
}
