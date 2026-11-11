// Дизайн-система Ghost: «жидкое стекло» (glassmorphism) поверх Mesh-фона.
//
// Карточки используют нативную рефракцию по краям поверх mesh; кнопки и поля
// сохраняют свои компактные стеклянные поверхности.
//
// Использование:
//   GlassCard(child: Text('...'))
//   GlassButton(label: 'Войти', onTap: () {...}, primary: true)
//   GlassInput(controller: ctrl, hint: 'Юзернейм', icon: CupertinoIcons.person)
//   GlassAppBar(title: 'Чаты', leading: BackButton())
//   showGlassSheet(context, child: ...)

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart' show HapticFeedback, TextInputFormatter;
import '../services/performance_service.dart';
import '../services/ghost_sound_effects.dart';
import '../services/theme_service.dart';
import '../theme.dart';
import 'liquid_glass.dart';

/// Редизайн: глобальное «жидкое/матовое стекло» выключено — оно лагало и
/// выглядело грязно на списках. Все поверхности этого файла рисуются плоскими:
/// сплошная заливка, без BackdropFilter, градиентов, glow и рамок.
/// Точечное матовое стекло (навбар, шиты) выносится отдельным виджетом позже.
bool get _flat => true;

/// true только в ThemeStyle.traditional — тоже плоский (без blur), как
/// minimal/mono, но карточки/кнопки получают мягкую нейтральную тень вместо
/// цветного glow (см. _softShadow ниже) — "айфоновский" вид вместо голого
/// плоского. minimal/mono намеренно остаются совсем без тени.
bool get _traditional =>
    ThemeService.instance.styleNotifier.value == ThemeStyle.traditional &&
    !PerformanceService.instance.reducedEffects;

/// Мягкая нейтральная тень для traditional — на основе GE.bg (не акцента:
/// в iOS тень нейтральная, не подсвечивается цветом кнопки/карточки).
List<BoxShadow> _softShadow({double blur = 16, double dy = 4}) => [
  BoxShadow(
    color: (GE.currentBrightness == Brightness.dark ? GE.shadow : GE.muted)
        .withValues(
          alpha: GE.currentBrightness == Brightness.dark ? 0.45 : 0.14,
        ),
    blurRadius: blur,
    offset: Offset(0, dy),
  ),
];

/// Общая "живая" пружинная физика для тапов/тумблеров/появления элементов —
/// один набор параметров (перенесён из утверждённого HTML-прототипа), чтобы
/// моторика ощущалась одинаково по всему приложению: реальная пружина
/// (mass-spring-damper) с перелётом ×1.6 и сильным squash-and-stretch ×3.2.
class GhostSpring {
  GhostSpring._();

  static const double ampMul = 1.6;
  static const double squashStrong = 3.2;

  static final SpringDescription desc = SpringDescription(
    mass: 1,
    stiffness: 180,
    damping: 12,
  );

  /// Пик скорости на пути -1→0 — нормирует squash/stretch по текущей
  /// скорости пружины (как в JS-прототипе), считается один раз лениво.
  static final double maxAbsV = _computeMaxAbsV();

  static double _computeMaxAbsV() {
    final sim = SpringSimulation(desc, -1, 0, 0);
    double maxV = 0;
    double t = 0;
    const dt = 1 / 120;
    while (!sim.isDone(t) && t < 3) {
      final v = sim.dx(t).abs();
      if (v > maxV) maxV = v;
      t += dt;
    }
    return maxV == 0 ? 1 : maxV;
  }

  static SpringSimulation run() => SpringSimulation(desc, -1, 0, 0);
}

/// Пружинное нажатие: "взвод" (сжатие) пока держат палец, и пружинный
/// возврат с перелётом + squash-and-stretch при отпускании — та же физика,
/// что в утверждённом демо кнопки. Оборачивает кнопки/карточки/строки
/// списков. onLongPress получает свою (более сильную) хаптику — так на
/// ощупь отличимо "тап" от "долгое нажатие → меню/выделение".
class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool haptic;

  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.haptic = true,
  });

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> with TickerProviderStateMixin {
  // Целевая деформация во "взведённом" состоянии (палец держит) — та же
  // формула, что squash/stretch в основной пружине, на пике STRONG-сжатия.
  static final double _squeezeX = 1 + 0.05 * GhostSpring.squashStrong * 0.33;
  static final double _squeezeY = 1 - 0.08 * GhostSpring.squashStrong * 0.33;

  late final AnimationController _pressCtrl; // 0..1, взвод при удержании
  late final AnimationController _springCtrl; // unbounded, отпускание пружиной
  double _releaseFromX = 1, _releaseFromY = 1;

  @override
  void initState() {
    super.initState();
    _pressCtrl = AnimationController(
      vsync: this,
      duration: PerformanceService.instance.animationControllerDuration(
        const Duration(milliseconds: 110),
      ),
    );
    _springCtrl = AnimationController.unbounded(vsync: this);
  }

  @override
  void dispose() {
    _pressCtrl.dispose();
    _springCtrl.dispose();
    super.dispose();
  }

  void _down() {
    if (PerformanceService.instance.animationQuality != AnimationQuality.best) {
      return;
    }
    _springCtrl.stop();
    _pressCtrl.forward(from: _pressCtrl.value);
  }

  void _release() {
    if (PerformanceService.instance.animationQuality != AnimationQuality.best) {
      _pressCtrl.stop();
      _springCtrl.stop();
      _pressCtrl.value = 0;
      return;
    }
    // Стартуем пружину РОВНО с текущей деформации, даже если взвод не успел
    // доиграть до конца — иначе будет прыжок (тот самый баг, что чинили у
    // тумблера).
    final p = Curves.easeOut.transform(_pressCtrl.value);
    _releaseFromX = 1 + (_squeezeX - 1) * p;
    _releaseFromY = 1 + (_squeezeY - 1) * p;
    _pressCtrl.stop();
    _pressCtrl.value = 0;
    _springCtrl.stop();
    _springCtrl.animateWith(GhostSpring.run());
  }

  @override
  Widget build(BuildContext context) {
    final tappable = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: tappable ? (_) => _down() : null,
      onTapUp: tappable ? (_) => _release() : null,
      onTapCancel: tappable ? _release : null,
      onTap: tappable
          ? () {
              unawaited(GhostSoundEffects.instance.playTap());
              if (widget.haptic) HapticFeedback.lightImpact();
              widget.onTap!();
            }
          : null,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              if (widget.haptic) HapticFeedback.mediumImpact();
              widget.onLongPress!();
            },
      child: AnimatedBuilder(
        animation: Listenable.merge([_pressCtrl, _springCtrl]),
        builder: (_, child) {
          double sx, sy;
          if (_springCtrl.isAnimating) {
            final x = _springCtrl.value;
            final mul = x < 0 ? 1.0 : GhostSpring.ampMul;
            sx = 1 + x * (1 - _releaseFromX) * mul;
            sy = 1 + x * (1 - _releaseFromY) * mul;
          } else {
            final p = Curves.easeOut.transform(_pressCtrl.value);
            sx = 1 + (_squeezeX - 1) * p;
            sy = 1 + (_squeezeY - 1) * p;
          }
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(sx, sy, 1),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// Тумблер: та же пружинная физика, что в PressScale/утверждённом демо —
/// перед основным ходом точка на 90мс "отъезжает" назад, в сторону,
/// противоположную переключению (как взведённая пружина), затем летит к
/// цели с перелётом и squash-and-stretch. Прямая замена стокового
/// Material Switch (тот же набор параметров: value/onChanged/activeColor).
class GhostSwitch extends StatefulWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? activeColor;

  const GhostSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
  });

  @override
  State<GhostSwitch> createState() => _GhostSwitchState();
}

class _GhostSwitchState extends State<GhostSwitch>
    with TickerProviderStateMixin {
  static const double _trackW = 52, _trackH = 30, _knob = 24, _pad = 3;
  static const double _travel = _trackW - _pad * 2 - _knob; // 22
  static const double _anticipDist = 4.5;

  late final AnimationController _anticipCtrl;
  late final AnimationController _springCtrl;
  double _from = 0, _to = 0, _pulledBack = 0;

  @override
  void initState() {
    super.initState();
    _from = _to = widget.value ? _travel : 0;
    _anticipCtrl = AnimationController(
      vsync: this,
      duration: PerformanceService.instance.animationControllerDuration(
        const Duration(milliseconds: 90),
      ),
    );
    _springCtrl = AnimationController.unbounded(vsync: this);
  }

  @override
  void didUpdateWidget(covariant GhostSwitch old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _run(old.value, widget.value);
  }

  @override
  void dispose() {
    _anticipCtrl.dispose();
    _springCtrl.dispose();
    super.dispose();
  }

  Future<void> _run(bool wasOn, bool nowOn) async {
    if (PerformanceService.instance.animationQuality != AnimationQuality.best) {
      _anticipCtrl.stop();
      _springCtrl.stop();
      _from = _to = nowOn ? _travel : 0;
      return;
    }
    _from = wasOn ? _travel : 0;
    _to = nowOn ? _travel : 0;
    final dir = (_to - _from) == 0 ? 1.0 : (_to - _from).sign;
    _pulledBack = _from - dir * _anticipDist;
    _springCtrl.stop();
    _anticipCtrl.stop();
    _anticipCtrl.value = 0;
    await _anticipCtrl.forward();
    if (!mounted) return;
    _springCtrl.animateWith(GhostSpring.run());
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.activeColor ?? GE.primary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onChanged == null
          ? null
          : () {
              unawaited(GhostSoundEffects.instance.playTap());
              HapticFeedback.lightImpact();
              widget.onChanged?.call(!widget.value);
            },
      child: AnimatedBuilder(
        animation: Listenable.merge([_anticipCtrl, _springCtrl]),
        builder: (_, _) {
          double knobX;
          double scaleX = 1, scaleY = 1;
          if (_springCtrl.isAnimating) {
            final x = _springCtrl.value;
            final v = _springCtrl.velocity;
            final mul = x < 0 ? 1.0 : GhostSpring.ampMul;
            knobX = _to + x * (_to - _pulledBack) * mul;
            final speed = (v.abs() / GhostSpring.maxAbsV).clamp(0.0, 1.0);
            scaleX = 1 + speed * 0.16 * GhostSpring.squashStrong * 0.33;
            scaleY = 1 - speed * 0.10 * GhostSpring.squashStrong * 0.33;
          } else if (_anticipCtrl.isAnimating) {
            final p = _anticipCtrl.value;
            final rem = 1 - p;
            final eased = 1 - rem * rem; // easeOutQuad
            knobX = _from + (_pulledBack - _from) * eased;
            final squeeze = 1 - 0.06 * eased;
            scaleX = squeeze;
            scaleY = 1 / squeeze;
          } else {
            knobX = widget.value ? _travel : 0;
          }
          final colorT = (knobX / _travel).clamp(0.0, 1.0);
          final trackColor = Color.lerp(
            GE.text.withValues(alpha: 0.10),
            active,
            colorT,
          )!;
          return Container(
            width: _trackW,
            height: _trackH,
            padding: const EdgeInsets.all(_pad),
            decoration: BoxDecoration(
              color: trackColor,
              borderRadius: BorderRadius.circular(_trackH / 2),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: knobX,
                  top: 0,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.diagonal3Values(scaleX, scaleY, 1),
                    child: Container(
                      width: _knob,
                      height: _knob,
                      decoration: const BoxDecoration(
                        color: GE.text,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Три точки бегущей волной — единый лоадер вместо разномастных
/// CircularProgressIndicator (кнопки, статус-строки и т.п.).
class GlassDots extends StatefulWidget {
  final Color color;
  final double size;
  const GlassDots({super.key, required this.color, this.size = 4});

  @override
  State<GlassDots> createState() => _GlassDotsState();
}

class _GlassDotsState extends State<GlassDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = (_ctrl.value + i * 0.25) % 1.0;
            final opacity =
                0.25 + 0.75 * (0.5 + 0.5 * math.sin(phase * 2 * math.pi));
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.size * 0.35),
              child: Opacity(
                opacity: opacity,
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

// ── "Liquid glass" токены — зеркало веб-фронта (--gl-* в chat/index.html) ──
// Многослойное стекло БЕЗ полагания на один только blur: диагональный блик
// (сверху-слева) + inset-подсветка через разные цвета сторон Border (Flutter
// не умеет CSS inset-shadow напрямую — этим и эмулируем: светлый верх/лево,
// тёмный низ/право, как будто стекло вдавлено).
class _GlassTokens {
  // Приглушено (было 0.12/0.075 у первого стопа) — на полной яркости блик
  // читался как типовой "AI-сгенерированный" глянец; сдержаннее = дороже.
  static LinearGradient sheen({bool strong = false}) => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: strong
        ? [
            GE.text.withValues(alpha: 0.07),
            GE.text.withValues(alpha: 0.02),
            GE.text.withValues(alpha: 0.01),
          ]
        : [
            GE.text.withValues(alpha: 0.045),
            GE.text.withValues(alpha: 0.014),
            GE.text.withValues(alpha: 0.008),
          ],
    stops: const [0.0, 0.55, 1.0],
  );

  static List<BoxShadow> shadow({bool strong = false}) => [
    BoxShadow(
      color: GE.shadow.withValues(alpha: strong ? 0.45 : 0.30),
      blurRadius: strong ? 32 : 18,
      offset: Offset(0, strong ? 10 : 6),
    ),
  ];
}

/// Полупрозрачная карточка-стекло. По умолчанию закруглена 16px.
/// Параметр [glow] подсвечивает фиолетовым (для CTA / выбранных).
/// Параметр [strong] — более глубокая версия для модалок/шитов (глубже фон,
/// ярче inset-подсветка, тяжелее тень) — зеркало --gl-bg-deep на вебе.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double? radius;
  final bool glow;
  final bool strong;
  final VoidCallback? onTap;
  final Color? fillOverride;
  final double? blurOverride;

  /// lite=true — не добавляет отдельный матовый blur. При включённой
  /// рефракции жидкого стекла карта lensMap всё равно применяется, иначе на
  /// списочных карточках оставался бы только нарисованный контур без эффекта.
  final bool lite;

  /// true — эта карточка оборачивает СПИСОК строк (Настройки, Разрешения и
  /// т.п.), а не одиночный виджет/кнопку/превью. Все поверхности подчиняются
  /// настройке "Фон карточки" (ThemeService.listPlatesNotifier): когда она
  /// выключена, заливка/блюр/тень самой карточки убираются одинаково для
  /// обычных чатов, LAN, закладок, профиля и настроек.
  final bool isListSection;

  /// Служебные поверхности (например, сама строка переключателя) остаются
  /// видимыми, даже когда пользователь отключил фон карточек.
  final bool ignoreSurfaceToggle;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius,
    this.glow = false,
    this.strong = false,
    this.onTap,
    this.fillOverride,
    this.blurOverride,
    this.lite = false,
    this.isListSection = false,
    this.ignoreSurfaceToggle = false,
  });

  @override
  Widget build(BuildContext context) {
    // Оба переключателя применяются сразу ко всем уже открытым карточкам:
    // «Фон списков» управляет только GlassCard(isListSection: true), а
    // «Жидкое стекло карточек» включает/выключает нативную рефракцию.
    // Не оборачиваем поверхность в AnimatedSwitcher: каждый элемент списка
    // получает собственный transition/saveLayer, из-за чего BackdropFilter мог
    // кратко исчезать при первом касании или во время прокрутки. Настройки
    // всё равно обновляются реактивно, а сама геометрия поверхности должна
    // оставаться постоянной.
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.listPlatesNotifier,
        ThemeService.instance.liquidGlassNotifier,
        ThemeService.instance.glassTintNotifier,
        ThemeService.instance.matteGlassNotifier,
        LiquidGlassEngine.shaderReadyNotifier,
        PerformanceService.instance.reducedEffectsNotifier,
      ]),
      builder: (context, _) {
        final showListPlates = ThemeService.instance.listPlatesNotifier.value;
        final reducedEffects = PerformanceService.instance.reducedEffects;
        final liquidGlassEnabled =
            ThemeService.instance.liquidGlassNotifier.value && !reducedEffects;
        final glassTintEnabled = ThemeService.instance.glassTintNotifier.value;
        final matteGlassEnabled =
            ThemeService.instance.matteGlassNotifier.value && !reducedEffects;
        return _buildCard(
          context,
          showListPlates,
          liquidGlassEnabled,
          glassTintEnabled,
          matteGlassEnabled,
        );
      },
    );
  }

  Widget _buildCard(
    BuildContext context,
    bool showListPlates,
    bool liquidGlassEnabled,
    bool glassTintEnabled,
    bool matteGlassEnabled,
  ) {
    final radiusObj = BorderRadius.circular(radius ?? GE.radiusMd);
    if (!showListPlates && !ignoreSurfaceToggle) {
      // Фон выключен — без заливки/рамки/тени вообще, только сам контент.
      // Это намеренно действует на все поверхности: LAN, закладки, профиль
      // и отдельные карточки не должны отличаться от обычных диалогов.
      Widget bare = Padding(padding: padding, child: child);
      if (onTap != null) bare = PressScale(onTap: onTap, child: bare);
      return bare;
    }
    if (_flat) {
      // Редизайн: сплошная поверхность без blur/градиента/тени и без рамок.
      Widget flatCard = DecoratedBox(
        decoration: BoxDecoration(
          color: fillOverride ?? (strong ? GE.surfaceElevated : GE.surface),
          borderRadius: radiusObj,
        ),
        child: Padding(padding: padding, child: child),
      );
      if (onTap != null) {
        flatCard = PressScale(onTap: onTap, child: flatCard);
      }
      return ClipRRect(borderRadius: radiusObj, child: flatCard);
    }
    final base =
        fillOverride ??
        (strong
            ? Color.alphaBlend(GE.bgDeep.withValues(alpha: 0.85), GE.glassFill)
            : (lite ? GE.glassFill.withValues(alpha: 0.55) : GE.glassFill));
    if (liquidGlassEnabled || matteGlassEnabled) {
      // Реальное стекло всегда имеет нейтральную полупрозрачную поверхность.
      // Если оставить её прозрачной при выключенном «цветном фоне», как было
      // раньше, рефракция на тёмном mesh почти не видна и карточка выглядит
      // как одна рамка. Переключатель tint теперь отвечает только за более
      // насыщенную тематическую заливку.
      final surfaceColor = glassTintEnabled
          ? (fillOverride ?? base)
          : (fillOverride ?? base).withValues(alpha: lite ? 0.36 : 0.45);
      Widget fill = DecoratedBox(
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: radiusObj,
          border: Border.all(
            color: Color(
              LiquidGlassEngine.borderColorValue(GE.borderStrong.toARGB32()),
            ),
            width: 1,
          ),
        ),
        child: Padding(padding: padding, child: child),
      );
      if (!lite || liquidGlassEnabled) {
        // Один bounded-клип остаётся СНАРУЖИ фильтра и совпадает с реальными
        // границами карточки. Важно не вкладывать второй backdrop-фильтр:
        // несколько saveLayer на scrolling backdrop и давали мигание.
        final refraction = liquidGlassEnabled
            ? LiquidGlassEngine.refractionFilter(
                radius: radiusObj.topLeft.x,
                devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              )
            : null;
        // Один BackdropFilter на поверхность надёжнее двух вложенных слоёв:
        // matte остаётся читаемым fallback, а shader не конкурирует с blur за
        // один и тот же scrolling backdrop.
        final filter =
            refraction ??
            (matteGlassEnabled || liquidGlassEnabled
                ? LiquidGlassEngine.blurFilter(blurOverride ?? GE.glassBlur)
                : null);
        if (filter != null) {
          fill = ClipRRect(
            borderRadius: radiusObj,
            clipBehavior: Clip.antiAlias,
            child: BackdropFilter(
              filter: filter,
              // Page transitions and some gesture animations use a saveLayer;
              // src avoids the filtered backdrop being multiplied away there.
              blendMode: BlendMode.src,
              child: fill,
            ),
          );
        } else {
          fill = ClipRRect(
            borderRadius: radiusObj,
            clipBehavior: Clip.antiAlias,
            child: fill,
          );
        }
      } else {
        // Lite surfaces without liquid glass still get an exact rounded clip.
        fill = ClipRRect(
          borderRadius: radiusObj,
          clipBehavior: Clip.antiAlias,
          child: fill,
        );
      }
      if (onTap != null) {
        fill = PressScale(onTap: onTap, child: fill);
      }
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radiusObj,
          boxShadow: [
            BoxShadow(
              color: GE.shadow.withValues(
                alpha: LiquidGlassEngine.cardShadowOpacity,
              ),
              blurRadius: LiquidGlassEngine.cardShadowBlur,
              offset: const Offset(0, LiquidGlassEngine.cardShadowDy),
            ),
            if (glow) BoxShadow(color: GE.glowFill, blurRadius: 20),
          ],
        ),
        child: fill,
      );
    }
    // Базовая заливка (тонкий вертикальный градиент глубины) + диагональный
    // блик (сверху-слева) поверх — двухслойная имитация жидкого стекла с сайта.
    final fillDeco = BoxDecoration(
      borderRadius: radiusObj,
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.alphaBlend(GE.text.withValues(alpha: 0.05), base),
          base,
          Color.alphaBlend(GE.shadow.withValues(alpha: 0.10), base),
        ],
        stops: const [0.0, 0.5, 1.0],
      ),
      // Без border: Border с разными цветами по сторонам (см. недавно
      // удалённый _GlassTokens.insetBorder) несовместим с borderRadius —
      // Flutter кидает "A borderRadius can only be given on borders with
      // uniform colors" при paint (в debug-сборке — assert, видно сразу;
      // в release — assert просто вырезан, но эффект всё равно не тот,
      // что задуман). Диагональный sheen-блик ниже даёт похожую подсветку
      // без этого столкновения, да и borders договорились убрать везде.
    );
    Widget fill = DecoratedBox(
      decoration: fillDeco,
      child: DecoratedBox(
        // Диагональный блик — отдельный слой ПОВЕРХ заливки (не смешиваем в
        // одном LinearGradient, т.к. у блика своя ось topLeft→bottomRight).
        decoration: BoxDecoration(
          borderRadius: radiusObj,
          gradient: _GlassTokens.sheen(strong: strong),
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
    if (!lite) {
      final baseFill = fill;
      fill = ClipRRect(
        borderRadius: radiusObj,
        child: liquidGlassEnabled
            ? BackdropFilter(
                filter: LiquidGlassEngine.blurFilter(
                  blurOverride ?? GE.glassBlur,
                ),
                child: baseFill,
              )
            : baseFill,
      );
    }
    if (onTap != null) {
      fill = PressScale(onTap: onTap, child: fill);
    }
    // Тень — СНАРУЖИ ClipRRect (иначе блюр её срезает). Отрывает карточку от
    // фона → объём вместо «плоско».
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radiusObj,
        boxShadow: [
          ..._GlassTokens.shadow(strong: strong),
          if (glow) BoxShadow(color: GE.glowFill, blurRadius: 20),
        ],
      ),
      child: fill,
    );
  }
}

/// Кнопка-стекло. [primary]=true → фиолетовый градиент (CTA).
/// [danger]=true → красно-розовый.
class GlassButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool primary;
  final bool danger;
  final bool loading;
  final bool fullWidth;
  final bool ignoreSurfaceToggle;

  /// Continuous-corner ("squircle", как у иконок/кнопок iOS) вместо обычного
  /// circular radius — opt-in для сравнения дизайнов, не меняет остальные
  /// кнопки по умолчанию.
  final bool squircle;

  const GlassButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.primary = false,
    this.danger = false,
    this.loading = false,
    this.fullWidth = false,
    this.ignoreSurfaceToggle = false,
    this.squircle = false,
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      ThemeService.instance.liquidGlassNotifier,
      ThemeService.instance.glassTintNotifier,
      ThemeService.instance.matteGlassNotifier,
      ThemeService.instance.listPlatesNotifier,
      LiquidGlassEngine.shaderReadyNotifier,
      PerformanceService.instance.reducedEffectsNotifier,
    ]),
    builder: (context, _) => _buildButton(context),
  );

  Widget _buildButton(BuildContext context) {
    final radius = BorderRadius.circular(GE.radiusSm);
    final clipper = squircle
        ? ContinuousRectangleBorder(borderRadius: radius)
        : null;
    final isCta = primary || danger;
    final reducedEffects = PerformanceService.instance.reducedEffects;
    final liquid =
        ThemeService.instance.liquidGlassNotifier.value && !reducedEffects;
    final matte =
        ThemeService.instance.matteGlassNotifier.value && !reducedEffects;
    final tint = ThemeService.instance.glassTintNotifier.value;
    final showSurface =
        ignoreSurfaceToggle || ThemeService.instance.listPlatesNotifier.value;
    final flat = _flat && !liquid && !matte;
    final hiddenSurface = !showSurface && !isCta;
    final surfaceFill = !showSurface
        ? Colors.transparent
        : (tint || liquid
              ? GE.glassFill.withValues(alpha: tint ? 0.45 : 0.32)
              : GE.surface);
    final gradient = (flat || !primary || hiddenSurface)
        ? null
        : LinearGradient(
            colors: [GE.primary2, GE.primary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );
    // GE.red (не хардкод-розовый) — иначе кнопка "Выйти"/удалить не меняла
    // тон на других 11 темах.
    final gradient2 = (flat || !danger || hiddenSurface)
        ? null
        : LinearGradient(
            colors: [
              GE.red,
              Color.alphaBlend(GE.shadow.withValues(alpha: 0.18), GE.red),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );
    // Редизайн: фиолетовый — акцент, не заливка. Основная кнопка получает
    // приглушённую фиолетовую подложку, остальные — обычную поверхность.
    final flatColor = !flat
        ? null
        : (primary
              ? GE.accentSoft
              : (danger ? GE.red : surfaceFill));
    // GE.text вслепую годился, пока CTA-заливка (primary/red) была
    // насыщенным акцентом на тёмном/светлом фоне — так совпадало почти
    // всегда. В монотоне primary/red/text — один и тот же "чернильный"
    // цвет: подпись сливалась бы с собственной заливкой кнопки (см. onColor
    // в theme.dart — единственный реальный предохранитель).
    final labelBg =
        flatColor ?? (isCta ? (primary ? GE.primary : GE.red) : surfaceFill);
    final labelColor = onColor(labelBg);
    Widget content = AnimatedContainer(
      duration: PerformanceService.instance.animationDuration(
        const Duration(milliseconds: 140),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      decoration: BoxDecoration(
        color: flatColor,
        // Не-CTA получает sheen-градиент стекла вместо плоской заливки.
        gradient: flat || hiddenSurface
            ? null
            : (gradient ??
                  gradient2 ??
                  LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.alphaBlend(
                        GE.text.withValues(alpha: 0.10),
                        surfaceFill,
                      ),
                      surfaceFill,
                    ],
                  )),
        borderRadius: radius,
        // CTA — uniform specular-кромка на цветном градиенте. Не-CTA — без
        // border (см. GlassCard.fillDeco про несовместимость borderRadius
        // с не-uniform-цветным Border — та же ловушка была и тут).
        border: hiddenSurface
            ? null
            : flat
            ? (isCta ? null : Border.all(color: GE.border, width: 1))
            : (isCta
                  ? Border.all(
                      color: GE.text.withValues(alpha: 0.24),
                      width: GE.glassStroke,
                    )
                  : null),
        // Приглушённое CTA-свечение (было alpha 0.38/blur 20 — читалось как
        // типовой "неоновый" AI-глянец); теперь тише и плотнее — дороже.
        boxShadow: (!flat && isCta)
            ? [
                BoxShadow(
                  color: (primary ? GE.primary : GE.red).withValues(
                    alpha: 0.22,
                  ),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
              ]
            : (_traditional && isCta)
            ? _softShadow(blur: 10, dy: 3)
            : null,
      ),
      child: Row(
        mainAxisSize: fullWidth ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (loading)
            GlassDots(color: labelColor, size: 5)
          else if (icon != null) ...[
            Icon(icon, size: 16, color: labelColor),
            const SizedBox(width: 8),
          ],
          if (!loading)
            Text(
              label,
              style: TextStyle(
                color: labelColor,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
        ],
      ),
    );
    if (!isCta && !flat && !hiddenSurface) {
      // Для non-CTA используем один bounded-фильтр: нативная линза или
      // blur-fallback без Impeller. Вложенные BackdropFilter здесь дают
      // лишний saveLayer и нестабильное поведение на анимациях.
      final refraction = liquid
          ? LiquidGlassEngine.refractionFilter(
              radius: radius.topLeft.x,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            )
          : null;
      final filter =
          refraction ??
          (matte ? LiquidGlassEngine.blurFilter(GE.glassBlur) : null);
      if (filter != null) {
        content = BackdropFilter(
          filter: filter,
          blendMode: BlendMode.src,
          child: content,
        );
      }
      content = clipper != null
          ? ClipPath(
              clipper: ShapeBorderClipper(shape: clipper),
              child: content,
            )
          : ClipRRect(borderRadius: radius, child: content);
    } else if (clipper != null) {
      content = ClipPath(
        clipper: ShapeBorderClipper(shape: clipper),
        child: content,
      );
    }
    final tappable = PressScale(onTap: loading ? null : onTap, child: content);
    return fullWidth
        ? SizedBox(width: double.infinity, child: tappable)
        : tappable;
  }
}

/// Компактная иконка действия с управляемой подложкой карточки.
/// В традиционном стиле фон нейтральный и без цветного glow; при отключении
/// фона карточек исчезает только подложка, зона нажатия сохраняется.
class GhostIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;

  const GhostIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.color,
  });

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: ThemeService.instance.listPlatesNotifier,
    builder: (context, showSurface, _) {
      final traditional =
          ThemeService.instance.styleNotifier.value == ThemeStyle.traditional;
      final radius = BorderRadius.circular(GE.radiusSm);
      final content = Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: showSurface
              ? GE.surface.withValues(alpha: traditional ? 0.92 : 0.58)
              : Colors.transparent,
          borderRadius: radius,
          border: showSurface ? Border.all(color: GE.border, width: 0.7) : null,
          boxShadow: showSurface && traditional
              ? [
                  BoxShadow(
                    color: GE.shadow.withValues(alpha: 0.22),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Icon(icon, color: color ?? GE.sub, size: 20),
      );
      final button = PressScale(onTap: onPressed, child: content);
      return tooltip == null
          ? button
          : Tooltip(message: tooltip!, child: button);
    },
  );
}

/// Поле ввода-стекло. С иконкой слева и опциональным suffix.
class GlassInput extends StatelessWidget {
  final TextEditingController? controller;
  final String? hint;
  final IconData? icon;
  final Widget? suffix;
  final bool obscure;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;
  final bool autofocus;
  final bool enabled;
  final int? minLines;
  final int? maxLines;
  final List<TextInputFormatter>? inputFormatters;
  final TextCapitalization textCapitalization;
  final bool autocorrect;
  final int? maxLength;
  final bool hideCounter;
  final TextAlign textAlign;
  final TextStyle? textStyle;
  final TextStyle? hintStyle;
  final EdgeInsetsGeometry? contentPadding;

  /// lite=true — без BackdropFilter (без blur). Для полей внутри уже размытого
  /// glass-шита: второй blur поверх размывал бы собственную заливку шита
  /// (двойной blur — дорого и почти без визуальной разницы), см. GlassCard.lite.
  final bool lite;

  const GlassInput({
    super.key,
    this.controller,
    this.hint,
    this.icon,
    this.suffix,
    this.obscure = false,
    this.keyboardType,
    this.validator,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.autofocus = false,
    this.enabled = true,
    this.minLines,
    this.maxLines = 1,
    this.inputFormatters,
    this.textCapitalization = TextCapitalization.none,
    this.autocorrect = true,
    this.maxLength,
    this.hideCounter = false,
    this.textAlign = TextAlign.start,
    this.textStyle,
    this.hintStyle,
    this.contentPadding,
    this.lite = false,
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      ThemeService.instance.liquidGlassNotifier,
      ThemeService.instance.glassTintNotifier,
      ThemeService.instance.matteGlassNotifier,
      LiquidGlassEngine.shaderReadyNotifier,
      PerformanceService.instance.reducedEffectsNotifier,
    ]),
    builder: (context, _) => _buildField(context),
  );

  Widget _buildField(BuildContext context) {
    final radius = BorderRadius.circular(GE.radiusSm);
    final reducedEffects = PerformanceService.instance.reducedEffects;
    final liquid =
        ThemeService.instance.liquidGlassNotifier.value && !reducedEffects;
    final matte =
        ThemeService.instance.matteGlassNotifier.value && !reducedEffects;
    final tint = ThemeService.instance.glassTintNotifier.value;
    final flat = _flat && !liquid && !matte;
    Widget field = Container(
      decoration: BoxDecoration(
        color: tint || liquid
            ? GE.glassFill.withValues(alpha: tint ? 0.45 : 0.32)
            : Colors.transparent,
        border: Border.all(
          color: flat ? GE.border : GE.glassBorder,
          width: GE.glassStroke,
        ),
        borderRadius: radius,
      ),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboardType,
        validator: validator,
        onChanged: onChanged,
        onFieldSubmitted: onSubmitted,
        onTap: onTap,
        autofocus: autofocus,
        enabled: enabled,
        inputFormatters: inputFormatters,
        buildCounter: hideCounter
            ? (
                _, {
                required int currentLength,
                required int? maxLength,
                required bool isFocused,
              }) => null
            : null,
        textCapitalization: textCapitalization,
        autocorrect: autocorrect,
        maxLength: maxLength,
        textAlign: textAlign,
        minLines: obscure ? null : minLines,
        maxLines: obscure ? 1 : maxLines,
        style: TextStyle(
          color: GE.text,
          fontSize: 14,
          fontWeight: FontWeight.w400,
        ).merge(textStyle),
        cursorColor: GE.primary,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            color: GE.sub,
            fontSize: 14,
            fontWeight: FontWeight.w400,
          ).merge(hintStyle),
          prefixIcon: icon != null ? Icon(icon, size: 18, color: GE.sub) : null,
          suffixIcon: suffix,
          border: InputBorder.none,
          contentPadding:
              contentPadding ??
              const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        ),
      ),
    );
    if (!flat && !lite) {
      final refraction = liquid
          ? LiquidGlassEngine.refractionFilter(
              radius: radius.topLeft.x,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            )
          : null;
      final filter =
          refraction ??
          (matte ? LiquidGlassEngine.blurFilter(GE.glassBlur) : null);
      if (filter != null) {
        field = BackdropFilter(
          filter: filter,
          blendMode: BlendMode.src,
          child: field,
        );
      }
    }
    return ClipRRect(borderRadius: radius, child: field);
  }
}

/// AppBar в glass-стиле — прозрачный с backdrop blur, без тени.
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget? title;
  final String? titleText;
  final Widget? leading;
  final List<Widget>? actions;
  final bool showBack;

  const GlassAppBar({
    super.key,
    this.title,
    this.titleText,
    this.leading,
    this.actions,
    this.showBack = false,
  });

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      ThemeService.instance.liquidGlassNotifier,
      ThemeService.instance.glassTintNotifier,
      ThemeService.instance.matteGlassNotifier,
      LiquidGlassEngine.shaderReadyNotifier,
      PerformanceService.instance.reducedEffectsNotifier,
    ]),
    builder: (context, _) => _buildBar(context),
  );

  Widget _buildBar(BuildContext context) {
    final reducedEffects = PerformanceService.instance.reducedEffects;
    final liquid =
        ThemeService.instance.liquidGlassNotifier.value && !reducedEffects;
    final matte =
        ThemeService.instance.matteGlassNotifier.value && !reducedEffects;
    final tint = ThemeService.instance.glassTintNotifier.value;
    Widget bar = AppBar(
      backgroundColor: _flat
          ? GE.bg
          : (tint || liquid
                ? GE.glassFill.withValues(alpha: tint ? 0.45 : 0.32)
                : Colors.transparent),
      surfaceTintColor: Colors.transparent,
      shape: Border(
        bottom: BorderSide(
          color: _flat ? GE.border : GE.glassBorder,
          width: 0.5,
        ),
      ),
      title: title ?? (titleText != null ? Text(titleText!) : null),
      leading: leading ?? (showBack ? BackButton(color: GE.text) : null),
      actions: actions,
    );
    if (_flat && !liquid && !matte) return bar;
    // Тот же рецепт стекла, что и у GlassCard: сначала нативная рефракция,
    // затем опциональная матовость. На backend без shader-фильтров остаётся
    // blur-fallback, чтобы шапка не исчезала.
    final refraction = liquid
        ? LiquidGlassEngine.refractionFilter(
            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          )
        : null;
    final filter =
        refraction ??
        (matte ? LiquidGlassEngine.blurFilter(GE.glassBlur) : null);
    if (filter != null) {
      bar = BackdropFilter(
        filter: filter,
        blendMode: BlendMode.src,
        child: bar,
      );
    }
    return ClipRect(child: bar);
  }
}

Widget _filteredSheet(
  Widget child, {
  required bool liquid,
  required bool matte,
  required double devicePixelRatio,
}) {
  final refraction = liquid
      ? LiquidGlassEngine.refractionFilter(
          radius: 24,
          devicePixelRatio: devicePixelRatio,
        )
      : null;
  final filter =
      refraction ?? (matte ? LiquidGlassEngine.blurFilter(22) : null);
  if (filter != null) {
    child = BackdropFilter(
      filter: filter,
      blendMode: BlendMode.src,
      child: child,
    );
  }
  return child;
}

/// Показывает bottom-sheet в glass-стиле.
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  required Widget child,
  double? height,
  bool isScrollControlled = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    backgroundColor: Colors.transparent,
    barrierColor: GE.bg,
    builder: (ctx) {
      final reducedEffects = PerformanceService.instance.reducedEffects;
      final liquid =
          ThemeService.instance.liquidGlassNotifier.value && !reducedEffects;
      final matte =
          ThemeService.instance.matteGlassNotifier.value && !reducedEffects;
      final tint = ThemeService.instance.glassTintNotifier.value;
      final flat = _flat && !liquid && !matte;
      Widget sheetBody = DecoratedBox(
        // Шит поднят над контентом — "strong"-глубина, как модалки на сайте
        // (--gl-bg-deep + border-strong + shadow-deep). В минимализме —
        // сплошная заливка без blur/sheen/тени.
        decoration: BoxDecoration(
          color: flat
              ? GE.surface
              : (tint || liquid
                    ? Color.alphaBlend(
                        GE.bgDeep.withValues(alpha: 0.85),
                        GE.glassFill.withValues(alpha: tint ? 0.45 : 0.32),
                      )
                    : Colors.transparent),
          border: Border(
            top: BorderSide(
              color: flat ? GE.border : GE.text.withValues(alpha: 0.22),
              width: 1,
            ),
          ),
          boxShadow: flat
              ? (_traditional ? _softShadow(blur: 20, dy: -2) : null)
              : _GlassTokens.shadow(strong: true),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: flat || !tint ? null : _GlassTokens.sheen(strong: true),
          ),
          child: Padding(
            padding: EdgeInsets.only(
              top: 12,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: SizedBox(
              height: height,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Grab handle сверху
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: GE.borderStrong,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Flexible(child: child),
                ],
              ),
            ),
          ),
        ),
      );
      return ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: flat
            ? sheetBody
            : _filteredSheet(
                sheetBody,
                liquid: liquid,
                matte: matte,
                devicePixelRatio: MediaQuery.devicePixelRatioOf(ctx),
              ),
      );
    },
  );
}
