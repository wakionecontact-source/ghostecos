// Welcome-онбординг при первом запуске. PageView из 4 слайдов с анимациями.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import '../mesh_background.dart';

class WelcomeScreen extends StatefulWidget {
  final VoidCallback onDone;
  const WelcomeScreen({super.key, required this.onDone});
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _Slide {
  final IconData icon;
  final String title;
  final String body;
  final Color accent;
  const _Slide({
    required this.icon,
    required this.title,
    required this.body,
    required this.accent,
  });
}

List<_Slide> get _slides => [
  _Slide(
    icon: Icons.lock_outline,
    title: 'Ghost',
    body: 'Приватная экосистема. Один аккаунт — мессенджер, соцсеть и банк.',
    accent: GE.primary,
  ),
  _Slide(
    icon: Icons.shield_outlined,
    title: 'Sealed E2E',
    body: 'Шифрование P-256 + AES-GCM. Сервер не знает кто кому пишет — sealed sender как в Signal.',
    accent: GE.green,
  ),
  _Slide(
    icon: Icons.currency_bitcoin,
    title: 'Своя экономика',
    body: 'Gost / Soul / Prem — три валюты. Зарабатывай активностью, торгуй NFT, покупай у других.',
    accent: GE.yellow,
  ),
  _Slide(
    icon: Icons.forum_outlined,
    title: 'Своя лента',
    body: 'Посты, реакции, репосты, миниска. Без рекламы, без алгоритмов, без слежки.',
    accent: GE.red,
  ),
];

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _pageCtrl = PageController();
  int _page = 0;

  Future<void> _finish() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('welcome_done', true);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pageCtrl,
                onPageChanged: (i) => setState(() => _page = i),
                itemCount: _slides.length,
                itemBuilder: (_, i) => _SlideView(slide: _slides[i], visible: i == _page),
              ),
            ),
            // Точки-индикатор
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_slides.length, (i) {
                  final active = i == _page;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: active ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: active ? GE.primary : GE.sub.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),
            ),
            // Кнопки
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 40),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _finish,
                    child: Text('Пропустить',
                        style: TextStyle(color: GE.sub, fontSize: 14)),
                  ),
                  const Spacer(),
                  if (_page < _slides.length - 1)
                    _PrimaryButton(
                      label: 'Дальше',
                      icon: Icons.arrow_forward,
                      onTap: () => _pageCtrl.nextPage(
                        duration: const Duration(milliseconds: 350),
                        curve: Curves.easeOutCubic,
                      ),
                    )
                  else
                    _PrimaryButton(label: 'Начать', icon: Icons.bolt, onTap: _finish),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlideView extends StatefulWidget {
  final _Slide slide;
  final bool visible;
  const _SlideView({required this.slide, required this.visible});
  @override
  State<_SlideView> createState() => _SlideViewState();
}

class _SlideViewState extends State<_SlideView> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    if (widget.visible) _ctrl.forward();
  }

  @override
  void didUpdateWidget(_SlideView old) {
    super.didUpdateWidget(old);
    if (widget.visible) _ctrl.forward(from: 0); else _ctrl.reset();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    final slide = Tween<Offset>(
      begin: const Offset(0, 0.08), end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    final scale = Tween<double>(
      begin: 0.6, end: 1,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut));
    final s = widget.slide;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ScaleTransition(
                scale: scale,
                child: Container(
                  width: 120, height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [s.accent.withValues(alpha: 0.30), s.accent.withValues(alpha: 0)],
                    ),
                    border: Border.all(color: s.accent.withValues(alpha: 0.4), width: 1.5),
                  ),
                  child: Icon(s.icon, size: 60, color: s.accent),
                ),
              ),
              const SizedBox(height: 28),
              SlideTransition(
                position: slide,
                child: FadeTransition(
                  opacity: fade,
                  child: Text(
                    s.title,
                    style: TextStyle(
                      fontSize: 32, fontWeight: FontWeight.w800,
                      color: GE.text, letterSpacing: -0.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SlideTransition(
                position: slide,
                child: FadeTransition(
                  opacity: fade,
                  child: Text(
                    s.body,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15, height: 1.55, color: GE.sub,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _PrimaryButton({required this.label, required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [GE.primary, GE.primary2]),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: GE.primary.withValues(alpha: 0.4),
              blurRadius: 22, offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(
              color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700,
            )),
            const SizedBox(width: 8),
            Icon(icon, color: Colors.white, size: 18),
          ],
        ),
      ),
    );
  }
}
