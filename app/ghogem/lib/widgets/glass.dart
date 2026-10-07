import 'package:flutter/material.dart';
import '../theme.dart';

// FLAT — никаких границ, блюра и стекла. Только матовые заливки.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final Color? color;
  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.radius=14, this.onTap, this.color});
  @override Widget build(BuildContext context) {
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? GG.surface,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: child,
    );
    if (onTap!=null) return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(radius), child: card);
    return card;
  }
}

class GlassButton extends StatelessWidget {
  final String label; final VoidCallback? onTap; final IconData? icon; final bool primary; final bool danger;
  const GlassButton({super.key, required this.label, this.onTap, this.icon, this.primary=false, this.danger=false});
  @override Widget build(BuildContext context) {
    final bg = danger ? GG.red : primary ? GG.violet : GG.surface2;
    final fg = danger || primary ? Colors.white : GG.text;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon!=null) ...[Icon(icon, size: 16, color: fg), const SizedBox(width: 8)],
          Text(label, style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
        ]),
      ),
    );
  }
}
