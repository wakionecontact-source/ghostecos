// Mesh обои — анимированные частицы + линии между близкими. Имитация веб-mesh.js.
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'theme.dart';

class MeshBackground extends StatefulWidget {
  /// Дочерний виджет — необязательный. Без него работает как fullscreen фон.
  final Widget? child;
  final int? particleCount;
  const MeshBackground({super.key, this.child, this.particleCount});
  @override
  State<MeshBackground> createState() => _MeshBackgroundState();
}

class _Particle {
  double x, y, vx, vy;
  _Particle(this.x, this.y, this.vx, this.vy);
}

class _MeshBackgroundState extends State<MeshBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  final _rand = Random(42);
  List<_Particle> _particles = [];
  Size? _lastSize;

  /// На мобиле — половина частиц и медленный апдейт. На десктопе — полноценный.
  int get _effectiveParticleCount {
    if (widget.particleCount != null) return widget.particleCount!;
    if (kIsWeb) return 30;
    if (Platform.isAndroid || Platform.isIOS) return 18;
    return 40;
  }

  @override
  void initState() {
    super.initState();
    // Не самый частый repaint — раз в кадр всё равно, но логика тика
    // легче. Период 60s = более плавно медленнее.
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 60),
    )..repeat();
  }

  void _initParticles(Size size) {
    if (_lastSize == size) return;
    _lastSize = size;
    _particles = List.generate(_effectiveParticleCount, (_) {
      return _Particle(
        _rand.nextDouble() * size.width,
        _rand.nextDouble() * size.height,
        (_rand.nextDouble() - 0.5) * 0.4,
        (_rand.nextDouble() - 0.5) * 0.4,
      );
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Material нужен чтобы Text widgets не показывали жёлтое подчёркивание-ошибку
    // (DefaultTextStyle берётся из Material/Scaffold; без него Flutter рисует error-baseline).
    return Material(
      color: GE.bg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Фон один-в-один с сайтом (server/site/index.html body):
          // вертикальный линейный bg-deep→bg + два радиала-источника света.
          // 1) Базовый вертикальный градиент.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [GE.bgDeep, GE.bg],
              ),
            ),
          ),
          // 2) Радиальный свет сверху-слева (#7c3aed @ 0.18).
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.6, -1.0),
                radius: 1.1,
                colors: [GE.primary2.withValues(alpha: 0.18), Colors.transparent],
                stops: const [0, 0.6],
              ),
            ),
          ),
          // 3) Радиальный свет снизу-справа (#a855f7 @ 0.12) — этого не хватало,
          //    из-за чего фон выглядел плоским и «не как на сайте».
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(1.0, 1.0),
                radius: 1.1,
                colors: [GE.primary.withValues(alpha: 0.12), Colors.transparent],
                stops: const [0, 0.6],
              ),
            ),
          ),
          // Сетка частиц — RepaintBoundary изолирует mesh от UI поверх,
          // чтобы apple-blur и list-rebuild не triggered repaint mesh-холста
          // и наоборот.
          RepaintBoundary(
            child: LayoutBuilder(builder: (ctx, c) {
              final size = Size(c.maxWidth, c.maxHeight);
              _initParticles(size);
              return AnimatedBuilder(
                animation: _ctrl,
                builder: (_, __) {
                  _tick(size);
                  return CustomPaint(
                    size: size,
                    painter: _MeshPainter(_particles),
                  );
                },
              );
            }),
          ),
          if (widget.child != null) widget.child!,
        ],
      ),
    );
  }

  void _tick(Size size) {
    for (final p in _particles) {
      p.x += p.vx;
      p.y += p.vy;
      if (p.x < 0 || p.x > size.width) p.vx = -p.vx;
      if (p.y < 0 || p.y > size.height) p.vy = -p.vy;
    }
  }
}

class _MeshPainter extends CustomPainter {
  final List<_Particle> particles;
  static const _maxDist = 130.0;
  _MeshPainter(this.particles);

  @override
  void paint(Canvas canvas, Size size) {
    final dot = Paint()..color = GE.primary.withValues(alpha: 0.65);
    // Линии между близкими частицами
    for (int i = 0; i < particles.length; i++) {
      for (int j = i + 1; j < particles.length; j++) {
        final dx = particles[i].x - particles[j].x;
        final dy = particles[i].y - particles[j].y;
        final dist = sqrt(dx * dx + dy * dy);
        if (dist < _maxDist) {
          final alpha = (1 - dist / _maxDist) * 0.18;
          final line = Paint()
            ..color = GE.primary.withValues(alpha: alpha)
            ..strokeWidth = 0.8;
          canvas.drawLine(
            Offset(particles[i].x, particles[i].y),
            Offset(particles[j].x, particles[j].y),
            line,
          );
        }
      }
    }
    for (final p in particles) {
      canvas.drawCircle(Offset(p.x, p.y), 1.8, dot);
    }
  }

  @override
  bool shouldRepaint(_MeshPainter old) => true;
}
