// Welcome — экран приветствия (стиль 1.19.3: одна страница) в дизайне Ghost:
// mesh-фон + glass + фиолет. Плавная staggered-анимация входа + «дышащий»
// логотип (мягкий bob + пульс свечения). После «Далее» → экран разрешений.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../services/app_avatar_settings.dart';

class WelcomeScreen extends StatefulWidget {
  final VoidCallback onDone;
  const WelcomeScreen({super.key, required this.onDone});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with TickerProviderStateMixin {
  late final AnimationController _entrance; // одноразовое появление
  late final AnimationController _float; // бесконечное «дыхание» логотипа
  late final AnimationController _ring; // медленно вращающееся кольцо-нимб

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..forward();
    _float = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat(reverse: true);
    _ring = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 9000),
    )..repeat();
  }

  @override
  void dispose() {
    _entrance.dispose();
    _float.dispose();
    _ring.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('welcome_done', true);
    widget.onDone();
  }

  /// Появление элемента: fade + сдвиг снизу, по интервалу [start..end]
  /// общего контроллера _entrance (staggered-эффект).
  Widget _reveal(double start, double end, Widget child) {
    return AnimatedBuilder(
      animation: _entrance,
      child: child,
      builder: (context, c) {
        final t = Interval(
          start,
          end,
          curve: Curves.easeOutCubic,
        ).transform(_entrance.value);
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(offset: Offset(0, (1 - t) * 22), child: c),
        );
      },
    );
  }

  /// Логотип: мягкое двухцветное сияние + медленно вращающийся нимб-кольцо
  /// + сам призрак с лёгким bob/scale-«дыханием».
  Widget _animatedLogo() {
    return SizedBox(
      width: 154,
      height: 154,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Слой 1 — широкое двухцветное сияние позади всего.
          AnimatedBuilder(
            animation: _float,
            builder: (context, _) {
              final f = Curves.easeInOut.transform(_float.value);
              return Container(
                width: 150,
                height: 150,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: GE.primary.withValues(alpha: 0.20 + 0.16 * f),
                      blurRadius: 46 + 16 * f,
                      spreadRadius: 2,
                    ),
                    BoxShadow(
                      color: GE.blue.withValues(alpha: 0.12),
                      blurRadius: 64,
                      spreadRadius: -8,
                    ),
                  ],
                ),
              );
            },
          ),
          // Слой 2 — тонкий вращающийся нимб (sweep-градиент, кольцом).
          AnimatedBuilder(
            animation: _ring,
            builder: (context, _) {
              return Transform.rotate(
                angle: _ring.value * 2 * math.pi,
                child: Container(
                  width: 134,
                  height: 134,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(
                      colors: [
                        GE.primary.withValues(alpha: 0),
                        GE.primary.withValues(alpha: 0.85),
                        GE.blue.withValues(alpha: 0.55),
                        GE.primary.withValues(alpha: 0),
                      ],
                      stops: const [0.0, 0.22, 0.5, 0.78],
                    ),
                  ),
                  child: Center(
                    child: Container(
                      width: 127,
                      height: 127,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: GE.bg,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          // Слой 3 — сам призрак: лёгкий bob вверх-вниз + микро-scale.
          AnimatedBuilder(
            animation: _float,
            builder: (context, _) {
              final f = Curves.easeInOut.transform(_float.value);
              return Transform.translate(
                offset: Offset(0, -5 * f),
                child: Transform.scale(
                  scale: 1 + 0.025 * f,
                  child: Container(
                    width: 116,
                    height: 116,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          GE.primary.withValues(alpha: 0.35),
                          GE.primary.withValues(alpha: 0),
                        ],
                      ),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.22),
                        width: 1,
                      ),
                    ),
                    child: ValueListenableBuilder<int>(
                      valueListenable:
                          AppAvatarSettings.instance.selectedVariantNotifier,
                      builder: (_, variant, _) => ClipOval(
                        child: Image.asset(
                          AppAvatarSettings.instance.assetPathFor(variant),
                          width: 86,
                          height: 86,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            // LayoutBuilder + ConstrainedBox(minHeight) + IntrinsicHeight:
            // на портрете колонка ровно во всю высоту, Spacer'ы работают как
            // раньше (пиксель-в-пиксель). На альбомной ориентации (или
            // низком экране), где фиксированный контент выше доступной
            // высоты, Spacer'ы схлопываются до минимума и лишнее уезжает в
            // скролл вместо обрезки/наезда на карточку.
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        const Spacer(flex: 3),
                        _reveal(0.0, 0.5, _animatedLogo()),
                        const SizedBox(height: 26),
                        _reveal(
                          0.12,
                          0.55,
                          ShaderMask(
                            shaderCallback: (b) => LinearGradient(
                              colors: [Colors.white, GE.primary],
                            ).createShader(b),
                            child: const Text(
                              'GhostChat',
                              style: TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                letterSpacing: -0.5,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        _reveal(
                          0.20,
                          0.60,
                          Text(
                            'Приватное общение',
                            style: TextStyle(
                              color: GE.primary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const Spacer(flex: 2),
                        GlassCard(
                          padding: const EdgeInsets.symmetric(
                            vertical: 18,
                            horizontal: 18,
                          ),
                          child: Column(
                            children: [
                              _reveal(
                                0.34,
                                0.62,
                                const _Feature(
                                  icon: CupertinoIcons.lock,
                                  title: 'Защищённые сообщения',
                                  body:
                                      'Содержимое диалогов защищено шифрованием.',
                                ),
                              ),
                              const SizedBox(height: 16),
                              _reveal(
                                0.42,
                                0.70,
                                const _Feature(
                                  icon: CupertinoIcons.eye_slash,
                                  title: 'Контроль приватности',
                                  body:
                                      'Вы сами решаете, чем делиться и какие настройки использовать.',
                                ),
                              ),
                              const SizedBox(height: 16),
                              _reveal(
                                0.50,
                                0.78,
                                const _Feature(
                                  icon: CupertinoIcons.nosign,
                                  title: 'Без лишнего шума',
                                  body:
                                      'Никакой рекламы и навязчивых рекомендаций в общении.',
                                ),
                              ),
                              const SizedBox(height: 16),
                              _reveal(
                                0.58,
                                0.86,
                                const _Feature(
                                  icon: Icons.devices_outlined,
                                  title: 'На удобных устройствах',
                                  body:
                                      'Используйте приложение там, где вам удобно.',
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(flex: 3),
                        _reveal(
                          0.74,
                          1.0,
                          GlassButton(
                            label: 'Далее',
                            icon: CupertinoIcons.arrow_right,
                            primary: true,
                            fullWidth: true,
                            onTap: _finish,
                          ),
                        ),
                        const SizedBox(height: 28),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _Feature({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: GE.primary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: GE.primary, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: GE.text,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                body,
                style: TextStyle(color: GE.sub, fontSize: 12.5, height: 1.35),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
