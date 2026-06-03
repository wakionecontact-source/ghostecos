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

import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme.dart';

/// Полупрозрачная карточка-стекло. По умолчанию закруглена 16px.
/// Параметр [glow] подсвечивает фиолетовым (для CTA / выбранных).
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final bool glow;
  final VoidCallback? onTap;
  final Color? fillOverride;
  final double? blurOverride;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = GE.radiusMd,
    this.glow = false,
    this.onTap,
    this.fillOverride,
    this.blurOverride,
  });

  @override
  Widget build(BuildContext context) {
    final radiusObj = BorderRadius.circular(radius);
    Widget content = ClipRRect(
      borderRadius: radiusObj,
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: blurOverride ?? GE.glassBlur,
          sigmaY: blurOverride ?? GE.glassBlur,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: fillOverride ?? GE.glassFill,
            borderRadius: radiusObj,
            border: Border.all(color: GE.glassBorder, width: GE.glassStroke),
            boxShadow: glow
                ? [
                    BoxShadow(
                      color: GE.glowFill,
                      blurRadius: 26,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          padding: padding,
          child: child,
        ),
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      borderRadius: radiusObj,
      onTap: onTap,
      child: content,
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

  const GlassButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.primary = false,
    this.danger = false,
    this.loading = false,
    this.fullWidth = false,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(GE.radiusSm);
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
        gradient: gradient,
        color: isCta ? null : GE.glassFill,
        borderRadius: radius,
        border: isCta
            ? null
            : Border.all(color: GE.glassBorder, width: GE.glassStroke),
        boxShadow: isCta
            ? [
                BoxShadow(
                  color: (primary ? GE.primary : const Color(0xFFE11D48))
                      .withValues(alpha: 0.35),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: fullWidth ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (loading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2, color: Colors.white,
              ),
            )
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
      content = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: GE.glassBlur, sigmaY: GE.glassBlur),
          child: content,
        ),
      );
    }
    final tappable = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: loading ? null : onTap,
        child: content,
      ),
    );
    return fullWidth ? SizedBox(width: double.infinity, child: tappable) : tappable;
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
            autofocus: autofocus,
            maxLines: obscure ? 1 : maxLines,
            style: TextStyle(color: GE.text, fontSize: 14),
            cursorColor: GE.primary,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(color: GE.sub, fontSize: 14),
              prefixIcon:
                  icon != null ? Icon(icon, size: 18, color: GE.sub) : null,
              suffixIcon: suffix,
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
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
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: AppBar(
          backgroundColor: GE.bg.withValues(alpha: 0.45),
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
        child: Container(
          decoration: BoxDecoration(
            color: GE.glassFill,
            border: Border(top: BorderSide(color: GE.glassBorder, width: 1)),
          ),
          padding: EdgeInsets.only(
            top: 12,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          height: height,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Grab handle сверху
              Container(
                width: 40, height: 4,
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
}
