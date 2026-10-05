import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import '../../core/api/ws_client.dart';
import '../../core/storage/secure_store.dart';
import '../../shared/theme/app_theme.dart';
import '../auth/welcome_screen.dart';

/// Каркас главного экрана с нижней навигацией.
/// TODO(next): реальные экраны Чаты/Контакты/Каналы/Профиль.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  static const _titles = ['Чаты', 'Контакты', 'Каналы', 'Профиль'];
  static const _icons = [
    CupertinoIcons.chat_bubble,
    CupertinoIcons.person_2,
    CupertinoIcons.tag,
    CupertinoIcons.person,
  ];

  @override
  void initState() {
    super.initState();
    // Поднять WebSocket при наличии токена (фоновая доставка сообщений).
    WsClient.I.connect();
  }

  Future<void> _logout() async {
    await WsClient.I.disconnect();
    await SecureStore.I.clearSession();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const WelcomeScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_tab]),
        actions: [
          if (_tab == 3)
            IconButton(
              onPressed: _logout,
              icon: const Icon(CupertinoIcons.square_arrow_right, color: AppColors.sub),
            ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icons[_tab], size: 56, color: AppColors.faint),
            const SizedBox(height: 12),
            Text(
              '${_titles[_tab]} — скоро',
              style: const TextStyle(color: AppColors.sub, fontSize: 15),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        backgroundColor: AppColors.bgDeep,
        destinations: [
          for (var i = 0; i < _titles.length; i++)
            NavigationDestination(icon: Icon(_icons[i]), label: _titles[i]),
        ],
      ),
    );
  }
}
