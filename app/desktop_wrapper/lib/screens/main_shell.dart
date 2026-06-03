// MainShell — native sidebar + контент-зона (WebView пока для каждого раздела).
import 'dart:io';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../auth_service.dart';
import '../platform_webview.dart';

enum Section { chat, feed, bank }

extension SectionInfo on Section {
  String get label => {
    Section.chat: 'Чат',
    Section.feed: 'Лента',
    Section.bank: 'Банк',
  }[this]!;
  IconData get icon => {
    Section.chat: Icons.chat_bubble_outline,
    Section.feed: Icons.dynamic_feed_outlined,
    Section.bank: Icons.account_balance_wallet_outlined,
  }[this]!;
  String get path => {
    Section.chat: '/chat/',
    Section.feed: '/social',
    Section.bank: '/bank/',
  }[this]!;
}

class MainShell extends StatefulWidget {
  final VoidCallback onLoggedOut;
  const MainShell({super.key, required this.onLoggedOut});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  Section _section = Section.chat;
  String? _username;
  String? _displayName;
  String? _token;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadMe();
  }

  Future<void> _loadMe() async {
    final t = await AuthService.token();
    final u = await AuthService.username();
    final d = await AuthService.displayName();
    setState(() {
      _token = t; _username = u; _displayName = d; _loaded = true;
    });
  }

  String _injectScript() {
    if (_token == null) return '';
    final esc = _token!.replaceAll("'", r"\'");
    final u = (_username ?? '').replaceAll("'", r"\'");
    final dn = (_displayName ?? _username ?? '').replaceAll("'", r"\'");
    return '''
      try {
        localStorage.setItem('gs_token', '$esc');
        localStorage.setItem('gs_me', JSON.stringify({
          username: '$u', display_name: '$dn'
        }));
        document.cookie = 'gs_token=$esc; path=/; SameSite=Lax; Secure';
      } catch(e) {}
    ''';
  }

  void _switch(Section s) => setState(() => _section = s);

  Future<void> _logout() async {
    await AuthService.logout();
    widget.onLoggedOut();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        backgroundColor: GE.bg,
        body: Center(child: CircularProgressIndicator(color: GE.primary)),
      );
    }
    // Mobile (Android) — bottom-tabbar. Desktop — sidebar.
    final isMobile = Platform.isAndroid || Platform.isIOS;
    return Scaffold(
      backgroundColor: GE.bg,
      body: isMobile
          ? _mobileBody()
          : Row(children: [
              _Sidebar(
                current: _section,
                username: _username ?? '?',
                displayName: _displayName ?? _username ?? '?',
                onSwitch: _switch,
                onLogout: _logout,
              ),
              Expanded(child: _content()),
            ]),
      bottomNavigationBar: isMobile
          ? BottomNavigationBar(
              backgroundColor: GE.bgDeep,
              selectedItemColor: GE.primary,
              unselectedItemColor: GE.sub,
              currentIndex: _section.index,
              onTap: (i) => _switch(Section.values[i]),
              type: BottomNavigationBarType.fixed,
              items: [
                for (final s in Section.values)
                  BottomNavigationBarItem(icon: Icon(s.icon), label: s.label),
              ],
            )
          : null,
    );
  }

  Widget _mobileBody() {
    return SafeArea(child: _content());
  }

  Widget _content() {
    // Каждый раздел перерисовывается отдельным WebView, KeyedSubtree сохраняет state
    return IndexedStack(
      index: _section.index,
      children: [
        for (final s in Section.values)
          KeyedSubtree(
            key: ValueKey(s),
            child: GeWebView(
              url: '${GE.baseUrl}${s.path}',
              injectScript: _injectScript(),
            ),
          ),
      ],
    );
  }
}

class _Sidebar extends StatelessWidget {
  final Section current;
  final String username, displayName;
  final ValueChanged<Section> onSwitch;
  final VoidCallback onLogout;
  const _Sidebar({
    required this.current,
    required this.username,
    required this.displayName,
    required this.onSwitch,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: GE.bgDeep,
        border: Border(right: BorderSide(color: GE.border)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            child: ShaderMask(
              shaderCallback: (b) => const LinearGradient(
                colors: [Colors.white, GE.primary],
              ).createShader(b),
              child: const Text(
                'GhostEcos',
                style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w800,
                  color: Colors.white, letterSpacing: 0.5,
                ),
              ),
            ),
          ),
          const Divider(color: GE.border, height: 1),
          const SizedBox(height: 8),
          for (final s in Section.values)
            _NavItem(
              section: s,
              active: s == current,
              onTap: () => onSwitch(s),
            ),
          const Spacer(),
          const Divider(color: GE.border, height: 1),
          // User card
          InkWell(
            onTap: onLogout,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: [GE.primary, GE.primary2]),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: GE.text, fontSize: 13,
                                fontWeight: FontWeight.w600)),
                        Text('@$username',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: GE.sub, fontSize: 11)),
                      ],
                    ),
                  ),
                  const Icon(Icons.logout, color: GE.sub, size: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final Section section;
  final bool active;
  final VoidCallback onTap;
  const _NavItem({required this.section, required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: active ? GE.primary.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: active
              ? Border.all(color: GE.primary.withValues(alpha: 0.30))
              : null,
        ),
        child: Row(
          children: [
            Icon(section.icon,
                size: 18, color: active ? GE.primary : GE.sub),
            const SizedBox(width: 12),
            Text(section.label,
                style: TextStyle(
                  color: active ? GE.text : GE.sub,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 14,
                )),
          ],
        ),
      ),
    );
  }
}
