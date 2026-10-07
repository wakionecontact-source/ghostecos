import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';

/// Вход через сайт во внешнем браузере:
/// открывает /v2/auth с флагом native=ghogem — после входа сайт сам
/// показывает «Сейчас открою GhostGem…» и возвращает в приложение
/// по схеме ghogem://auth с данными.
class SiteAuthScreen extends StatefulWidget {
  final VoidCallback onLoggedIn;
  const SiteAuthScreen({super.key, required this.onLoggedIn});

  @override
  State<SiteAuthScreen> createState() => _SiteAuthScreenState();
}

class _SiteAuthScreenState extends State<SiteAuthScreen> {
  static const _siteUrl =
      'https://ghostecos.duckdns.org/v2/auth?mode=login&native=ghogem&app=GhostGem&icon=/ghogem/ghogemava.jpg';
  bool _opened = false;

  @override
  void initState() {
    super.initState();
    _openSite();
  }

  Future<void> _openSite() async {
    final uri = Uri.parse(_siteUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (mounted) setState(() => _opened = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GG.bg,
      appBar: AppBar(
        backgroundColor: GG.bgDeep,
        iconTheme: IconThemeData(color: GG.paper),
        title: Text(
          'Вход через сайт',
          style: TextStyle(color: GG.paper, fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: GG.violet,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                CupertinoIcons.globe,
                color: Colors.white,
                size: 26,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Продолжи в браузере',
              style: TextStyle(
                color: GG.paper,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '1. Войди на сайте GhostEcos (там можно выбрать аккаунт, если уже войдён).\n'
              '2. Страница скажет «Сейчас открою приложение» и вернёт тебя сюда с данными.',
              style: TextStyle(color: GG.muted, fontSize: 13, height: 1.6),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _openSite,
                icon: const Icon(CupertinoIcons.refresh, size: 18),
                label: Text(
                  _opened ? 'Открыть сайт снова' : 'Открыть сайт',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: GG.violet,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'После входа приложение откроется само',
                style: TextStyle(color: GG.faint, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
