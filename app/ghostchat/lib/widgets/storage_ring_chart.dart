// Кольцевая диаграмма хранилища — форма не круг и не квадрат жёстко, а
// суперэллипс (кривая Ламе), плавно меняющая форму вместе с настройкой
// "Скругление" во Внешнем виде (GE.cornerFactor/ThemeService.cornerNotifier):
// острый угол (factor→0) даёт почти квадрат, круглый (factor→1) — окружность.
// Сегменты — категории хранилища, доли пропорциональны байтам, с небольшим
// зазором между соседними для читаемости (как в донат-чарте Telegram).
import 'dart:math' as math;
import 'package:flutter/material.dart';

class StorageSegment {
  final String id;
  final String label;
  final int bytes;
  final Color color;
  const StorageSegment({
    this.id = '',
    required this.label,
    required this.bytes,
    required this.color,
  });
}

class StorageRingChart extends StatelessWidget {
  final List<StorageSegment> segments;
  final double
  cornerFactor; // 0=острый(90°) .. 1=круглый(45°), см. GE.cornerFactor
  final double size;

  /// Толщина кольца как доля от размера (0..0.5).
  final double thickness;
  final Widget? center;
  final int? selectedIndex;
  final ValueChanged<int>? onTap;

  const StorageRingChart({
    super.key,
    required this.segments,
    required this.cornerFactor,
    this.size = 220,
    this.thickness = 0.16,
    this.center,
    this.selectedIndex,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final chart = SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          TweenAnimationBuilder<double>(
            key: ValueKey(
              '${segments.map((s) => '${s.id}:${s.bytes}').join('|')}|selected:$selectedIndex',
            ),
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            builder: (_, progress, __) => CustomPaint(
              size: Size.square(size),
              painter: _RingPainter(
                segments: segments,
                cornerFactor: cornerFactor.clamp(0.0, 1.0),
                thickness: thickness.clamp(0.02, 0.5),
                selectedIndex: selectedIndex,
                progress: progress,
              ),
            ),
          ),
          ?center,
        ],
      ),
    );
    if (onTap == null) return chart;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        final center = Offset(size / 2, size / 2);
        final delta = details.localPosition - center;
        final distance = delta.distance;
        final outer = size / 2;
        final inner = outer * (1 - thickness * 2).clamp(0.05, 0.98);
        if (distance < inner || distance > outer + 10) return;
        var angle = math.atan2(delta.dy, delta.dx) + math.pi / 2;
        if (angle < 0) angle += math.pi * 2;
        final total = segments.fold<int>(0, (sum, s) => sum + s.bytes);
        if (total <= 0) return;
        var cursor = 0.0;
        for (var i = 0; i < segments.length; i++) {
          final sweep = segments[i].bytes / total * math.pi * 2;
          if (angle >= cursor && angle < cursor + sweep) {
            onTap!(i);
            return;
          }
          cursor += sweep;
        }
      },
      child: chart,
    );
  }
}

class _RingPainter extends CustomPainter {
  final List<StorageSegment> segments;
  final double cornerFactor;
  final double thickness;
  final int? selectedIndex;
  final double progress;

  _RingPainter({
    required this.segments,
    required this.cornerFactor,
    required this.thickness,
    required this.selectedIndex,
    this.progress = 1.0,
  });

  /// Суперэллипс: n=2 — идеальный круг (cornerFactor=1), n=5 — "сквиркл",
  /// близкий к квадрату со скруглёнными углами (cornerFactor=0). Между ними —
  /// линейная интерполяция, даёт плавный переход круг↔квадрат.
  static double _exponentFor(double cornerFactor) => 5.0 - 3.0 * cornerFactor;

  Offset _pointOnSuperellipse(
    double angle,
    double radius,
    double n,
    Offset center,
  ) {
    final c = math.cos(angle), s = math.sin(angle);
    final x = _signedPow(c, n) * radius;
    final y = _signedPow(s, n) * radius;
    return Offset(center.dx + x, center.dy + y);
  }

  double _signedPow(double v, double n) {
    final a = v.abs();
    if (a < 1e-9) return 0;
    final p = math.pow(a, 2 / n).toDouble();
    return v < 0 ? -p : p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final total = segments.fold<int>(0, (sum, s) => sum + s.bytes);
    if (total <= 0 || segments.isEmpty) return;

    final center = Offset(size.width / 2, size.height / 2);
    final outerR = math.min(size.width, size.height) / 2;
    final innerR = outerR * (1 - thickness * 2).clamp(0.05, 0.98);
    final n = _exponentFor(cornerFactor);

    const gap = 0.045; // радиан зазора между сегментами
    const startAngle = -math.pi / 2; // с "12 часов", как обычный донат-чарт
    const pointsPerSegment = 48;

    double angle = startAngle;
    for (var index = 0; index < segments.length; index++) {
      final seg = segments[index];
      final fraction = seg.bytes / total;
      if (fraction <= 0) continue;
      final sweep = fraction * (2 * math.pi) * progress - gap;
      if (sweep <= 0.001) {
        angle += fraction * (2 * math.pi);
        continue;
      }
      final segStart = angle + gap / 2;
      final segEnd = segStart + sweep;
      final selected = index == selectedIndex;
      final mid = (segStart + segEnd) / 2;
      final shift = selected
          ? Offset(math.cos(mid) * 6, math.sin(mid) * 6)
          : Offset.zero;
      final drawOuterR = selected ? outerR * 1.04 : outerR;
      final drawInnerR = selected ? innerR * 1.04 : innerR;

      final path = Path();
      for (var i = 0; i <= pointsPerSegment; i++) {
        final a = segStart + (segEnd - segStart) * i / pointsPerSegment;
        final p = _pointOnSuperellipse(a, drawOuterR, n, center + shift);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      for (var i = pointsPerSegment; i >= 0; i--) {
        final a = segStart + (segEnd - segStart) * i / pointsPerSegment;
        final p = _pointOnSuperellipse(a, drawInnerR, n, center + shift);
        path.lineTo(p.dx, p.dy);
      }
      path.close();

      canvas.drawPath(
        path,
        Paint()
          ..color = seg.color
          ..style = PaintingStyle.fill,
      );
      angle += fraction * (2 * math.pi) * progress;
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.segments != segments ||
      old.cornerFactor != cornerFactor ||
      old.thickness != thickness ||
      old.selectedIndex != selectedIndex ||
      old.progress != progress;
}
