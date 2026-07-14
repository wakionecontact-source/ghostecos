// Дизайн-система Ghost: «жидкое стекло» (glassmorphism) поверх Mesh-фона.
//
// Все карточки/кнопки/поля используют BackdropFilter с blur, полупрозрачную
// заливку и тонкий бордер — даёт ощущение прозрачного стекла поверх mesh.
//
// Использование:
//   GlassCard(child: Text('...'))
//   GlassButton(label: 'Войти', onTap: () {...}, primary: true)
//   GlassInput(controller: ctrl, hint: 'Юзернейм', icon: Icons.person_outline)
//   GlassAppBar(title: 'Чаты', leading: BackButton())
//   showGlassSheet(context, child: ...)

import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import '../services/theme_service.dart';
import '../theme.dart';

/// true в ThemeStyle.minimal — карточки/кнопки/поля ниже рисуются плоско
/// (без BackdropFilter, без градиентов и glow), см. project memory
/// «минималистичный режим». Все виджеты этого файла читают этот флаг
/// напрямую при каждом build(), рёбилд обеспечивает вызывающий экран,
/// который уже слушает ThemeService.instance.notifier (стиль меняет
/// палитру-«близнеца», см. ThemeService.setStyle).
bool get _flat => ThemeService.instance.styleNotifier.value == ThemeStyle.minimal;

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

class _PressScaleState extends State<PressScale>
    with TickerProviderStateMixin {
  // Целевая деформация во "взведённом" состоянии (палец держит) — та же
  // формула, что squash/stretch в основной пружине, на пике STRONG-сжатия.
  static final double _squeezeX =
      1 + 0.05 * GhostSpring.squashStrong * 0.33;
  static final double _squeezeY =
      1 - 0.08 * GhostSpring.squashStrong * 0.33;

  late final AnimationController _pressCtrl; // 0..1, взвод при удержании
  late final AnimationController _springCtrl; // unbounded, отпускание пружиной
  double _releaseFromX = 1, _releaseFromY = 1;

  @override
  void initState() {
    super.initState();
    _pressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 110),
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
    _springCtrl.stop();
    _pressCtrl.forward(from: _pressCtrl.value);
  }

  void _release() {
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
  final ValueChanged<bool> onChanged;
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
      duration: const Duration(milliseconds: 90),
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
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onChanged(!widget.value);
      },
      child: AnimatedBuilder(
        animation: Listenable.merge([_anticipCtrl, _springCtrl]),
        builder: (_, __) {
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
            Colors.white.withValues(alpha: 0.10),
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
                        color: Colors.white,
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

class _GlassDotsState extends State<GlassDots> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();
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
            final opacity = 0.25 + 0.75 * (0.5 + 0.5 * math.sin(phase * 2 * math.pi));
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.size * 0.35),
              child: Opacity(
                opacity: opacity,
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
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
                Colors.white.withValues(alpha: 0.07),
                Colors.white.withValues(alpha: 0.02),
                Colors.white.withValues(alpha: 0.01),
              ]
            : [
                Colors.white.withValues(alpha: 0.045),
                Colors.white.withValues(alpha: 0.014),
                Colors.white.withValues(alpha: 0.008),
              ],
        stops: const [0.0, 0.55, 1.0],
      );

  static List<BoxShadow> shadow({bool strong = false}) => [
        BoxShadow(
          color: Colors.black.withValues(alpha: strong ? 0.45 : 0.30),
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

  /// lite=true — без BackdropFilter (без blur). На списочных tile это
  /// единственный способ сохранить 60fps на мобиле — blur на каждом item
  /// убивает GPU. Визуально почти не отличить, потому что mesh-фон видно.
  final bool lite;

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
  });

  @override
  Widget build(BuildContext context) {
    final radiusObj = BorderRadius.circular(radius ?? GE.radiusMd);
    if (_flat) {
      // Минимализм: сплошная заливка + тонкая рамка, без blur/градиента/тени.
      Widget flatCard = DecoratedBox(
        decoration: BoxDecoration(
          color: fillOverride ?? GE.surface,
          borderRadius: radiusObj,
          border: Border.all(color: GE.border, width: 1),
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
    // Базовая заливка (тонкий вертикальный градиент глубины) + диагональный
    // блик (сверху-слева) поверх — двухслойная имитация жидкого стекла с сайта.
    final fillDeco = BoxDecoration(
      borderRadius: radiusObj,
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.alphaBlend(Colors.white.withValues(alpha: 0.05), base),
          base,
          Color.alphaBlend(Colors.black.withValues(alpha: 0.10), base),
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
      fill = ClipRRect(
        borderRadius: radiusObj,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: blurOverride ?? GE.glassBlur,
            sigmaY: blurOverride ?? GE.glassBlur,
          ),
          child: fill,
        ),
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
    this.squircle = false,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(GE.radiusSm);
    final clipper = squircle ? ContinuousRectangleBorder(borderRadius: radius) : null;
    final isCta = primary || danger;
    final flat = _flat;
    final gradient = (flat || !primary)
        ? null
        : LinearGradient(
            colors: [GE.primary2, GE.primary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );
    // GE.red (не хардкод-розовый) — иначе кнопка "Выйти"/удалить не меняла
    // тон на других 11 темах.
    final gradient2 = (flat || !danger)
        ? null
        : LinearGradient(
            colors: [
              GE.red,
              Color.alphaBlend(Colors.black.withValues(alpha: 0.18), GE.red),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );
    // Минимализм: сплошной цвет вместо градиента, без blur/glow-тени.
    final flatColor = !flat
        ? null
        : (primary ? GE.primary : (danger ? GE.red : GE.glassFill));
    Widget content = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      decoration: BoxDecoration(
        color: flatColor,
        // Не-CTA получает sheen-градиент стекла вместо плоской заливки.
        gradient: flat
            ? null
            : (gradient ??
                  gradient2 ??
                  LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.alphaBlend(
                        Colors.white.withValues(alpha: 0.10),
                        GE.glassFill,
                      ),
                      GE.glassFill,
                    ],
                  )),
        borderRadius: radius,
        // CTA — uniform specular-кромка на цветном градиенте. Не-CTA — без
        // border (см. GlassCard.fillDeco про несовместимость borderRadius
        // с не-uniform-цветным Border — та же ловушка была и тут).
        border: flat
            ? (isCta ? null : Border.all(color: GE.border, width: 1))
            : (isCta
                  ? Border.all(
                      color: Colors.white.withValues(alpha: 0.24),
                      width: GE.glassStroke,
                    )
                  : null),
        // Приглушённое CTA-свечение (было alpha 0.38/blur 20 — читалось как
        // типовой "неоновый" AI-глянец); теперь тише и плотнее — дороже.
        boxShadow: (!flat && isCta)
            ? [
                BoxShadow(
                  color: (primary ? GE.primary : GE.red).withValues(alpha: 0.22),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: fullWidth ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (loading)
            const GlassDots(color: Colors.white, size: 5)
          else if (icon != null) ...[
            Icon(icon, size: 16, color: GE.text),
            const SizedBox(width: 8),
          ],
          if (!loading)
            Text(
              label,
              style: TextStyle(
                color: GE.text,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
        ],
      ),
    );
    if (!isCta && !flat) {
      // Для non-CTA добавляем backdrop blur — реальное «стекло» (пропускаем
      // в минимализме — там и так сплошная заливка, blur не нужен).
      content = clipper != null
          ? ClipPath(
              clipper: ShapeBorderClipper(shape: clipper),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: GE.glassBlur, sigmaY: GE.glassBlur),
                child: content,
              ),
            )
          : ClipRRect(
              borderRadius: radius,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: GE.glassBlur, sigmaY: GE.glassBlur),
                child: content,
              ),
            );
    } else if (clipper != null) {
      content = ClipPath(clipper: ShapeBorderClipper(shape: clipper), child: content);
    }
    final tappable = PressScale(onTap: loading ? null : onTap, child: content);
    return fullWidth
        ? SizedBox(width: double.infinity, child: tappable)
        : tappable;
  }
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
  final int? maxLines;

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
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(GE.radiusSm);
    final flat = _flat;
    Widget field = Container(
      decoration: BoxDecoration(
        color: GE.glassFill,
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
        maxLines: obscure ? 1 : maxLines,
        style: TextStyle(color: GE.text, fontSize: 14),
        cursorColor: GE.primary,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: GE.sub, fontSize: 14),
          prefixIcon: icon != null ? Icon(icon, size: 18, color: GE.sub) : null,
          suffixIcon: suffix,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        ),
      ),
    );
    if (!flat) {
      field = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: GE.glassBlur, sigmaY: GE.glassBlur),
        child: field,
      );
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
  Widget build(BuildContext context) {
    final bar = AppBar(
      backgroundColor: GE.glassFill,
      surfaceTintColor: Colors.transparent,
      shape: Border(
        bottom: BorderSide(color: _flat ? GE.border : GE.glassBorder, width: 0.5),
      ),
      title: title ?? (titleText != null ? Text(titleText!) : null),
      leading: leading ?? (showBack ? BackButton(color: GE.text) : null),
      actions: actions,
    );
    if (_flat) return bar;
    // Тот же рецепт стекла, что и у GlassCard (blur+fill), чтобы шапка не
    // выглядела отдельным слоем — только edge-to-edge вместо скруглений.
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: GE.glassBlur, sigmaY: GE.glassBlur),
        child: bar,
      ),
    );
  }
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
    barrierColor: const Color(0xCC020617),
    builder: (ctx) {
      final flat = _flat;
      Widget sheetBody = DecoratedBox(
        // Шит поднят над контентом — "strong"-глубина, как модалки на сайте
        // (--gl-bg-deep + border-strong + shadow-deep). В минимализме —
        // сплошная заливка без blur/sheen/тени.
        decoration: BoxDecoration(
          color: flat
              ? GE.surface
              : Color.alphaBlend(
                  GE.bgDeep.withValues(alpha: 0.85),
                  GE.glassFill,
                ),
          border: Border(
            top: BorderSide(
              color: flat ? GE.border : Colors.white.withValues(alpha: 0.22),
              width: 1,
            ),
          ),
          boxShadow: flat ? null : _GlassTokens.shadow(strong: true),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: flat ? null : _GlassTokens.sheen(strong: true),
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
            : BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: sheetBody,
              ),
      );
    },
  );
}
