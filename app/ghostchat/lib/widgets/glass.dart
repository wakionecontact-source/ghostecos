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
import 'package:flutter/services.dart' show HapticFeedback;
import '../theme.dart';

/// Пружинное нажатие (лёгкое сжатие + возврат) + лёгкая хаптика — единый
/// "эпловский" отклик на тап вместо голого Material-ripple. Оборачивает
/// кнопки/карточки/строки списков. onLongPress получает свою (более сильную)
/// хаптику — так на ощупь отличимо "тап" от "долгое нажатие → меню/выделение".
class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scaleDown;
  final bool haptic;

  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scaleDown = 0.96,
    this.haptic = true,
  });

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (mounted && _pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final tappable = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: tappable ? (_) => _setPressed(true) : null,
      onTapUp: tappable ? (_) => _setPressed(false) : null,
      onTapCancel: tappable ? () => _setPressed(false) : null,
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
      child: AnimatedScale(
        scale: _pressed ? widget.scaleDown : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
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
  static LinearGradient sheen({bool strong = false}) => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: strong
            ? [
                Colors.white.withValues(alpha: 0.12),
                Colors.white.withValues(alpha: 0.03),
                Colors.white.withValues(alpha: 0.015),
              ]
            : [
                Colors.white.withValues(alpha: 0.075),
                Colors.white.withValues(alpha: 0.020),
                Colors.white.withValues(alpha: 0.010),
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
  final double radius;
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
    this.radius = GE.radiusMd,
    this.glow = false,
    this.strong = false,
    this.onTap,
    this.fillOverride,
    this.blurOverride,
    this.lite = false,
  });

  @override
  Widget build(BuildContext context) {
    final radiusObj = BorderRadius.circular(radius);
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
      fill = PressScale(onTap: onTap, scaleDown: 0.98, child: fill);
    }
    // Тень — СНАРУЖИ ClipRRect (иначе блюр её срезает). Отрывает карточку от
    // фона → объём вместо «плоско».
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radiusObj,
        boxShadow: [
          ..._GlassTokens.shadow(strong: strong),
          if (glow)
            BoxShadow(color: GE.glowFill, blurRadius: 30, spreadRadius: 1),
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
    final gradient = primary
        ? LinearGradient(
            colors: [GE.primary2, GE.primary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
        : danger
        ? const LinearGradient(
            colors: [Color(0xFFE11D48), Color(0xFFEC4899)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
        : null;
    Widget content = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      decoration: BoxDecoration(
        // Не-CTA получает sheen-градиент стекла вместо плоской заливки.
        gradient:
            gradient ??
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
            ),
        borderRadius: radius,
        // CTA — uniform specular-кромка на цветном градиенте. Не-CTA — без
        // border (см. GlassCard.fillDeco про несовместимость borderRadius
        // с не-uniform-цветным Border — та же ловушка была и тут).
        border: isCta
            ? Border.all(
                color: Colors.white.withValues(alpha: 0.24),
                width: GE.glassStroke,
              )
            : null,
        boxShadow: isCta
            ? [
                BoxShadow(
                  color: (primary ? GE.primary : const Color(0xFFE11D48))
                      .withValues(alpha: 0.38),
                  blurRadius: 20,
                  offset: const Offset(0, 7),
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
    if (!isCta) {
      // Для non-CTA добавляем backdrop blur — реальное «стекло»
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
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: GE.glassBlur, sigmaY: GE.glassBlur),
        child: Container(
          decoration: BoxDecoration(
            color: GE.glassFill,
            border: Border.all(color: GE.glassBorder, width: GE.glassStroke),
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
              prefixIcon: icon != null
                  ? Icon(icon, size: 18, color: GE.sub)
                  : null,
              suffixIcon: suffix,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 13,
              ),
            ),
          ),
        ),
      ),
    );
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
    // Тот же рецепт стекла, что и у GlassCard (blur+fill), чтобы шапка не
    // выглядела отдельным слоем — только edge-to-edge вместо скруглений.
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: GE.glassBlur, sigmaY: GE.glassBlur),
        child: AppBar(
          backgroundColor: GE.glassFill,
          surfaceTintColor: Colors.transparent,
          shape: Border(bottom: BorderSide(color: GE.glassBorder, width: 0.5)),
          title: title ?? (titleText != null ? Text(titleText!) : null),
          leading: leading ?? (showBack ? BackButton(color: GE.text) : null),
          actions: actions,
        ),
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
    builder: (ctx) => ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: DecoratedBox(
          // Шит поднят над контентом — "strong"-глубина, как модалки на сайте
          // (--gl-bg-deep + border-strong + shadow-deep).
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              GE.bgDeep.withValues(alpha: 0.85),
              GE.glassFill,
            ),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: 0.22),
                width: 1,
              ),
            ),
            boxShadow: _GlassTokens.shadow(strong: true),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: _GlassTokens.sheen(strong: true),
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
        ),
      ),
    ),
  );
}
