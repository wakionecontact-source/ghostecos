// Mesh-обои — частицы + линии между близкими. Механика 1-в-1 с web mesh.js:
//   • плотность по площади (~1 точка / 9000 px²),
//   • мягкий wrap краёв (не отскок),
//   • трение 0.96 + лёгкий постоянный дрейф (не замирают),
//   • отталкивание от касания/курсора (сила 1.5 в радиусе 150) + линии к нему,
//   • cap скорости 3.0 (анти-разгон),
//   • линии между точками <140px с альфой до 0.55 (видимая сеть).
// Фон-градиент (3 слоя) — как на сайте.
import 'dart:math';
import 'package:flutter/material.dart';
import 'theme.dart';

class MeshBackground extends StatefulWidget {
  /// Дочерний виджет поверх фона (необязателен).
  final Widget? child;
  final int? particleCount;
  const MeshBackground({super.key, this.child, this.particleCount});
  @override
  State<MeshBackground> createState() => _MeshBackgroundState();
}

class _Particle {
  double x, y, vx, vy, r;
  _Particle(this.x, this.y, this.vx, this.vy, this.r);
}

class _MeshBackgroundState extends State<MeshBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final _rand = Random();
  List<_Particle> _particles = [];
  Size? _lastSize;
  Offset? _touch; // позиция пальца/курсора (mouse в mesh.js)

  static const double _touchDist = 150;
  static const double _maxSpeed = 3.0;

  @override
  void initState() {
    super.initState();
    // Тикер: repeat() гонит rebuild каждый кадр (длительность роли не играет).
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  // mesh.js: ~1 точка на 9000 px², на мобиле скромнее по верхней границе (батарея).
  int _countFor(Size s) {
    if (widget.particleCount != null) return widget.particleCount!;
    return (s.width * s.height / 9000).round().clamp(30, 90);
  }

  _Particle _spawn(Size s) {
    final speed = 0.25 + _rand.nextDouble() * 0.35;
    final angle = _rand.nextDouble() * pi * 2;
    return _Particle(
      _rand.nextDouble() * s.width,
      _rand.nextDouble() * s.height,
      cos(angle) * speed,
      sin(angle) * speed,
      1.2 + _rand.nextDouble() * 1.3,
    );
  }

  void _initParticles(Size size) {
    final want = _countFor(size);
    if (_lastSize == size && _particles.length == want) return;
    _lastSize = size;
    if (_particles.isEmpty) {
      _particles = List.generate(want, (_) => _spawn(size));
    } else if (_particles.length < want) {
      for (var i = _particles.length; i < want; i++) {
        _particles.add(_spawn(size));
      }
    } else if (_particles.length > want) {
      _particles.length = want;
    }
  }

  void _tick(Size size) {
    final t = _touch;
    for (final p in _particles) {
      // Отталкивание от касания/курсора.
      if (t != null) {
        final dx = p.x - t.dx, dy = p.y - t.dy;
        final d2 = dx * dx + dy * dy;
        if (d2 < _touchDist * _touchDist && d2 > 0.01) {
          final d = sqrt(d2);
          final force = (1 - d / _touchDist) * 1.5;
          p.vx += (dx / d) * force;
          p.vy += (dy / d) * force;
        }
      }
      // Трение.
      p.vx *= 0.96;
      p.vy *= 0.96;
      // Лёгкий постоянный дрейф (чтобы не замирали).
      if (p.vx * p.vx + p.vy * p.vy < 0.05) {
        final a = _rand.nextDouble() * pi * 2;
        p.vx += cos(a) * 0.12;
        p.vy += sin(a) * 0.12;
      }
      // Cap скорости (анти-разгон от касания).
      final vSq = p.vx * p.vx + p.vy * p.vy;
      if (vSq > _maxSpeed * _maxSpeed) {
        final k = _maxSpeed / sqrt(vSq);
        p.vx *= k;
        p.vy *= k;
      }
      p.x += p.vx;
      p.y += p.vy;
      // Мягкие стены — wrap (как mesh.js), не отскок.
      if (p.x < -20) {
        p.x = size.width + 20;
      } else if (p.x > size.width + 20) {
        p.x = -20;
      }
      if (p.y < -20) {
        p.y = size.height + 20;
      } else if (p.y > size.height + 20) {
        p.y = -20;
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Listener — пассивный наблюдатель указателя: ловит позицию пальца/курсора
    // НЕ перехватывая жесты UI поверх (тапы/скроллы работают как обычно).
    return Listener(
      onPointerHover: (e) => _touch = e.localPosition,
      onPointerDown: (e) => _touch = e.localPosition,
      onPointerMove: (e) => _touch = e.localPosition,
      onPointerUp: (e) => _touch = null,
      onPointerCancel: (e) => _touch = null,
      child: Material(
        color: GE.bg,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Фон 1-в-1 с сайтом: вертикальный градиент + два радиала.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [GE.bgDeep, GE.bg],
                ),
              ),
            ),
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
            // Сетка частиц — изолирована RepaintBoundary от UI поверх.
            RepaintBoundary(
              child: LayoutBuilder(
                builder: (ctx, c) {
                  final size = Size(c.maxWidth, c.maxHeight);
                  _initParticles(size);
                  return AnimatedBuilder(
                    animation: _ctrl,
                    builder: (_, __) {
                      _tick(size);
                      return CustomPaint(
                        size: size,
                        painter: _MeshPainter(_particles, _touch),
                      );
                    },
                  );
                },
              ),
            ),
            if (widget.child != null) widget.child!,
          ],
        ),
      ),
    );
  }
}

class _MeshPainter extends CustomPainter {
  final List<_Particle> particles;
  final Offset? touch;
  static const double _linkDistSq = 140 * 140;
  static const double _touchDistSq = 150 * 150;
  _MeshPainter(this.particles, this.touch);

  @override
  void paint(Canvas canvas, Size size) {
    // Точки.
    final dot = Paint()..color = GE.primary.withValues(alpha: 0.85);
    for (final p in particles) {
      canvas.drawCircle(Offset(p.x, p.y), p.r, dot);
    }
    // Линии между близкими (видимая сеть — альфа до 0.55, как mesh.js).
    for (var i = 0; i < particles.length; i++) {
      final a = particles[i];
      for (var j = i + 1; j < particles.length; j++) {
        final b = particles[j];
        final dx = a.x - b.x, dy = a.y - b.y;
        final d2 = dx * dx + dy * dy;
        if (d2 < _linkDistSq) {
          final alpha = (1 - d2 / _linkDistSq) * 0.55;
          canvas.drawLine(
            Offset(a.x, a.y),
            Offset(b.x, b.y),
            Paint()
              ..color = GE.primary.withValues(alpha: alpha)
              ..strokeWidth = 1,
          );
        }
      }
    }
    // Линии от касания к ближайшим точкам.
    final t = touch;
    if (t != null) {
      for (final p in particles) {
        final dx = p.x - t.dx, dy = p.y - t.dy;
        final d2 = dx * dx + dy * dy;
        if (d2 < _touchDistSq) {
          final alpha = (1 - d2 / _touchDistSq) * 0.8;
          canvas.drawLine(
            t,
            Offset(p.x, p.y),
            Paint()
              ..color = GE.primary.withValues(alpha: alpha)
              ..strokeWidth = 1,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_MeshPainter old) => true;
}
