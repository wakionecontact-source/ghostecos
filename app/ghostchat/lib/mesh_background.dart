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
import 'services/theme_service.dart';
import 'services/performance_service.dart';
import 'theme.dart';

/// Наблюдатель маршрутов для mesh-фона: когда поверх экрана открывается другой
/// экран/диалог/боттом-шит, лежащий ниже MeshBackground перестаёт тикать
/// (см. RouteAware ниже) — иначе он жёг бы кадры под непрозрачным верхним
/// маршрутом. Регистрируется в MaterialApp.navigatorObservers (см. main.dart).
final RouteObserver<ModalRoute<dynamic>> meshRouteObserver =
    RouteObserver<ModalRoute<dynamic>>();

class MeshBackground extends StatefulWidget {
  /// Дочерний виджет поверх фона (необязателен).
  final Widget? child;
  final int? particleCount;

  /// Если false, mesh продолжает тикать под лёгкими overlay-маршрутами
  /// (например, контекстным меню сообщения), где фон всё ещё виден.
  final bool pauseWhenCovered;
  const MeshBackground({
    super.key,
    this.child,
    this.particleCount,
    this.pauseWhenCovered = true,
  });
  @override
  State<MeshBackground> createState() => _MeshBackgroundState();
}

class _Particle {
  double x, y, vx, vy, r;
  _Particle(this.x, this.y, this.vx, this.vy, this.r);
}

class _MeshBackgroundState extends State<MeshBackground>
    with SingleTickerProviderStateMixin, RouteAware, WidgetsBindingObserver {
  late final AnimationController _ctrl;
  final _rand = Random();
  List<_Particle> _particles = [];
  Size? _lastSize;
  Offset? _touch; // позиция пальца/курсора (mouse в mesh.js)
  DateTime? _lastFrameAt;
  int _frameId = 0;
  // true, когда поверх этого экрана открыт другой маршрут (экран/шит/диалог) —
  // тикер частиц ставится на паузу, чтобы не жечь кадры под перекрытием.
  bool _covered = false;
  bool _backgrounded = false;

  static const double _touchDist = 150;
  static const double _maxSpeed = 1.6;

  bool get _showParticles {
    final performance = PerformanceService.instance;
    final energyProfile = performance.energySavingActive;
    final enabledInEnergyProfile =
        !energyProfile || performance.energyMeshEnabled;
    // The dedicated energy-profile switch owns mesh visibility. A low GUI
    // quality profile must not silently hide it when that switch is enabled.
    return ThemeService.instance.meshNotifier.value &&
        enabledInEnergyProfile &&
        (!performance.reducedEffects ||
            (energyProfile && performance.energyMeshEnabled));
  }

  // Градиенты — только в «Классическом» стиле. Минимализм никогда не
  // показывает свечение/градиенты, даже если анимированный фон включён —
  // тогда видны только частицы поверх плоской заливки GE.bg.
  bool get _showGradients {
    final performance = PerformanceService.instance;
    final energyProfile = performance.energySavingActive;
    final enabledInEnergyProfile =
        !energyProfile || performance.energyMeshEnabled;
    return ThemeService.instance.styleNotifier.value == ThemeStyle.vivid &&
        enabledInEnergyProfile &&
        (!performance.reducedEffects ||
            (energyProfile && performance.energyMeshEnabled));
  }

  bool get _touchReactionEnabled =>
      ThemeService.instance.meshTouchReactionNotifier.value;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _backgrounded =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    // Тикер: repeat() гонит rebuild каждый кадр (длительность роли не играет).
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _syncTicker();
    ThemeService.instance.meshNotifier.addListener(_onMeshToggle);
    ThemeService.instance.styleNotifier.addListener(_onStyleChange);
    ThemeService.instance.meshSpeedNotifier.addListener(_onMeshSpeedChange);
    ThemeService.instance.meshTouchReactionNotifier.addListener(
      _onMeshTouchReactionChange,
    );
    PerformanceService.instance.reducedEffectsNotifier.addListener(
      _onPerformanceModeChange,
    );
    PerformanceService.instance.backgroundFpsNotifier.addListener(
      _onPerformanceModeChange,
    );
    PerformanceService.instance.appearanceBackgroundFpsNotifier.addListener(
      _onPerformanceModeChange,
    );
    PerformanceService.instance.energySavingActiveNotifier.addListener(
      _onPerformanceModeChange,
    );
    PerformanceService.instance.energyMeshEnabledNotifier.addListener(
      _onPerformanceModeChange,
    );
    PerformanceService.instance.energyMeshSpeedNotifier.addListener(
      _onPerformanceModeChange,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Подписываемся на маршрут, в котором живём, чтобы узнавать о перекрытии
    // сверху (didPushNext) и возврате (didPopNext). unsubscribe перед повторной
    // подпиской — на случай, если маршрут-предок сменился.
    meshRouteObserver.unsubscribe(this);
    final route = ModalRoute.of(context);
    if (route != null) meshRouteObserver.subscribe(this, route);
  }

  /// Гоняем тикер когда частицы включены; для обычных экранов паузим его
  /// при перекрытии, а для лёгких overlay (например, меню чата) продолжаем.
  void _syncTicker() {
    if (!_backgrounded &&
        _showParticles &&
        (!widget.pauseWhenCovered || !_covered)) {
      if (!_ctrl.isAnimating) _ctrl.repeat();
    } else {
      if (_ctrl.isAnimating) _ctrl.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _backgrounded = false;
      _syncTicker();
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _backgrounded = true;
      _syncTicker();
    }
  }

  // Поверх нас открыли другой маршрут — частицы не видны, тикать незачем.
  @override
  void didPushNext() {
    _covered = true;
    _syncTicker();
  }

  // Вернулись на этот экран — возобновляем (если частицы включены).
  @override
  void didPopNext() {
    _covered = false;
    _syncTicker();
  }

  void _onMeshToggle() {
    if (!mounted) return;
    _syncTicker();
    setState(() {});
  }

  void _onStyleChange() {
    if (mounted) setState(() {});
  }

  void _onMeshSpeedChange() {
    if (mounted) setState(() {});
  }

  void _onMeshTouchReactionChange() {
    if (!_touchReactionEnabled) _touch = null;
    if (mounted) setState(() {});
  }

  void _onPerformanceModeChange() {
    if (!mounted) return;
    _syncTicker();
    setState(() {});
  }

  // mesh.js: ~1 точка на 9000 px², на мобиле скромнее по верхней границе (батарея).
  int _countFor(Size s) {
    if (widget.particleCount != null) return widget.particleCount!;
    return (s.width * s.height / 9000).round().clamp(30, 90);
  }

  _Particle _spawn(Size s) {
    final speed = 0.12 + _rand.nextDouble() * 0.18;
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
    final performance = PerformanceService.instance;
    final speed = performance.energySavingActive
        ? performance.energyMeshSpeed
        : ThemeService.instance.meshSpeedNotifier.value;
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
      if (p.vx * p.vx + p.vy * p.vy < 0.018) {
        final a = _rand.nextDouble() * pi * 2;
        p.vx += cos(a) * 0.06;
        p.vy += sin(a) * 0.06;
      }
      // Cap скорости (анти-разгон от касания).
      final vSq = p.vx * p.vx + p.vy * p.vy;
      if (vSq > _maxSpeed * _maxSpeed) {
        final k = _maxSpeed / sqrt(vSq);
        p.vx *= k;
        p.vy *= k;
      }
      p.x += p.vx * speed;
      p.y += p.vy * speed;
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
    WidgetsBinding.instance.removeObserver(this);
    meshRouteObserver.unsubscribe(this);
    ThemeService.instance.meshNotifier.removeListener(_onMeshToggle);
    ThemeService.instance.styleNotifier.removeListener(_onStyleChange);
    ThemeService.instance.meshSpeedNotifier.removeListener(_onMeshSpeedChange);
    ThemeService.instance.meshTouchReactionNotifier.removeListener(
      _onMeshTouchReactionChange,
    );
    PerformanceService.instance.reducedEffectsNotifier.removeListener(
      _onPerformanceModeChange,
    );
    PerformanceService.instance.backgroundFpsNotifier.removeListener(
      _onPerformanceModeChange,
    );
    PerformanceService.instance.appearanceBackgroundFpsNotifier.removeListener(
      _onPerformanceModeChange,
    );
    PerformanceService.instance.energySavingActiveNotifier.removeListener(
      _onPerformanceModeChange,
    );
    PerformanceService.instance.energyMeshEnabledNotifier.removeListener(
      _onPerformanceModeChange,
    );
    PerformanceService.instance.energyMeshSpeedNotifier.removeListener(
      _onPerformanceModeChange,
    );
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showParticles = _showParticles;
    final showGradients = _showGradients;
    final reactToTouch = showParticles && _touchReactionEnabled;
    // Внимание: Listener → Material → Stack должны существовать ВСЕГДА, вне
    // зависимости от флагов ниже, одним и тем же поддеревом виджетов — иначе
    // при переключении тумблера/стиля Flutter видит смену типа поддерева в
    // этом слоте и пересоздаёт widget.child с нуля (сброс скролла/состояния
    // вложенных экранов). Меняется только состав children внутри Stack, а
    // child держится под стабильным Key на одной и той же позиции.
    return Listener(
      onPointerHover: reactToTouch ? (e) => _touch = e.localPosition : null,
      onPointerDown: reactToTouch ? (e) => _touch = e.localPosition : null,
      onPointerMove: reactToTouch ? (e) => _touch = e.localPosition : null,
      onPointerUp: reactToTouch ? (e) => _touch = null : null,
      onPointerCancel: reactToTouch ? (e) => _touch = null : null,
      child: Material(
        color: GE.bg,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (showGradients) ...[
              // Фон 1-в-1 с сайтом: вертикальный градиент + два радиала.
              // Классический стиль — показывается вне зависимости от
              // тумблера "Анимированный фон" (тот управляет только точками).
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
                    colors: [
                      GE.primary2.withValues(alpha: 0.18),
                      Colors.transparent,
                    ],
                    stops: const [0, 0.6],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(1.0, 1.0),
                    radius: 1.1,
                    colors: [
                      GE.primary.withValues(alpha: 0.12),
                      Colors.transparent,
                    ],
                    stops: const [0, 0.6],
                  ),
                ),
              ),
              // Нижнее свечение-градиент: стекло снизу (нав-бар, композер)
              // садится на него и выделяется/объёмится.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: const Alignment(0, 0.25),
                    colors: [
                      GE.primary.withValues(alpha: 0.22),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ],
            if (showParticles)
              // Сетка частиц — изолирована RepaintBoundary от UI поверх.
              // Показывается независимо от градиентов: в минимализме это
              // точки на плоском фоне без свечения.
              RepaintBoundary(
                child: LayoutBuilder(
                  builder: (ctx, c) {
                    final size = Size(c.maxWidth, c.maxHeight);
                    _initParticles(size);
                    return AnimatedBuilder(
                      animation: _ctrl,
                      builder: (_, _) {
                        final now = DateTime.now();
                        final fps = PerformanceService.instance.backgroundFps;
                        final frameInterval = Duration(
                          microseconds: (1000000 / fps).round(),
                        );
                        if (_lastFrameAt == null ||
                            now.difference(_lastFrameAt!) >= frameInterval) {
                          _lastFrameAt = now;
                          _tick(size);
                          _frameId++;
                        }
                        return CustomPaint(
                          size: size,
                          painter: _MeshPainter(
                            _particles,
                            _touchReactionEnabled ? _touch : null,
                            _frameId,
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            if (widget.child != null)
              KeyedSubtree(
                key: const ValueKey('mesh_child'),
                child: widget.child!,
              ),
          ],
        ),
      ),
    );
  }
}

class _MeshPainter extends CustomPainter {
  final List<_Particle> particles;
  final Offset? touch;
  final int frameId;
  static const double _linkDistSq = 140 * 140;
  static const double _touchDistSq = 150 * 150;
  _MeshPainter(this.particles, this.touch, this.frameId);

  @override
  void paint(Canvas canvas, Size size) {
    final accent = GE.primary;
    // Точки.
    final dot = Paint()..color = accent.withValues(alpha: 0.85);
    for (final p in particles) {
      canvas.drawCircle(Offset(p.x, p.y), p.r, dot);
    }
    // Один переиспользуемый Paint на все линии — раньше в O(n²)-цикле на КАЖДЫЙ
    // сегмент аллоцировался новый Paint (до ~тысяч объектов/кадр → мусор и
    // просадки на слабых устройствах). drawLine читает Paint в момент вызова,
    // поэтому мутировать цвет между вызовами безопасно.
    final line = Paint()..strokeWidth = 1;
    // Линии между близкими (видимая сеть — альфа до 0.55, как mesh.js).
    for (var i = 0; i < particles.length; i++) {
      final a = particles[i];
      for (var j = i + 1; j < particles.length; j++) {
        final b = particles[j];
        final dx = a.x - b.x, dy = a.y - b.y;
        final d2 = dx * dx + dy * dy;
        if (d2 < _linkDistSq) {
          final alpha = (1 - d2 / _linkDistSq) * 0.55;
          line.color = accent.withValues(alpha: alpha);
          canvas.drawLine(Offset(a.x, a.y), Offset(b.x, b.y), line);
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
          line.color = accent.withValues(alpha: alpha);
          canvas.drawLine(t, Offset(p.x, p.y), line);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_MeshPainter old) =>
      old.frameId != frameId || old.touch != touch;
}
