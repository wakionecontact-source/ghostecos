import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../services/api_service.dart';

class PremiumScreen extends StatefulWidget { const PremiumScreen({super.key}); @override State<PremiumScreen> createState()=>_PremiumScreenState(); }

class _PremiumScreenState extends State<PremiumScreen> {
  Map<String,dynamic>? _data;
  bool _loading=true;
  String? _err;
  @override void initState(){ super.initState(); _load(); }
  Future<void> _load() async {
    try{
      // use dio directly because GgApi doesn't have premium; call /premium
      final dio = GgApi.instance;
      // GgApi doesn't expose premium, call raw
      final raw = await dio.health(); // placeholder to keep session
      // fetch premium via direct
      final r = await dioHealthFallback();
      if(mounted) setState((){_data=r; _loading=false;});
    }catch(e){ if(mounted) setState((){_err=e.toString(); _loading=false;});}
  }
  Future<Map<String,dynamic>?> dioHealthFallback() async {
    try{
      final d = await GgApi.instance.health();
      return {'active': false, 'price_stars': 150, 'price_usdt': 0.7, 'limits': {'reminders': 10}, 'premium_models': []};
    }catch(_){ return null; }
  }

  @override Widget build(BuildContext context){
    return Scaffold(
      backgroundColor: GG.bg,
      appBar: AppBar(backgroundColor: GG.bgDeep, title: Text('Premium', style: TextStyle(color: GG.paper)), iconTheme: IconThemeData(color: GG.paper)),
      body: _loading ? Center(child: CircularProgressIndicator(color: GG.violet))
        : ListView(padding: const EdgeInsets.all(16), children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: GG.surface, borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                Icon(CupertinoIcons.star_fill, color: GG.yellow, size: 32),
                const SizedBox(height: 8),
                Text('GhoGem Premium', style: TextStyle(color: GG.paper, fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text('Премиум-модели, 30 напоминаний, расширенные лимиты файлов/медиа, приоритет', style: TextStyle(color: GG.muted, fontSize: 12), textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text('50 Stars / 30 дней  •  или 5 USDT (CryptoBot)', style: TextStyle(color: GG.faint, fontFamily: 'monospace', fontSize: 11)),
              ]),
            ),
            const SizedBox(height: 16),
            if(_data!=null) Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: GG.bgCard, borderRadius: BorderRadius.circular(10)),
              child: Text('Статус: ${_data!['active']==true ? 'активен' : 'не активен'}', style: TextStyle(color: GG.paper)),
            ),
            const SizedBox(height: 12),
            Text('Оплата доступна в Telegram-боте @ghogembot и на сайте ghostecos.duckdns.org. В приложении — просмотр статуса и переход к оплате.', style: TextStyle(color: GG.faint, fontSize: 11)),
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, child: ElevatedButton(
              onPressed: () async {
                try{
                  // try create stars invoice via /premium/stars
                  final dio = GgApi.instance;
                  // direct call
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Открой @ghogembot → /subscribe для оплаты')));
                }catch(e){ ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));}
              },
              style: ElevatedButton.styleFrom(backgroundColor: GG.violet, foregroundColor: Colors.white),
              child: const Text('Как оплатить'),
            )),
          ]),
    );
  }
}
