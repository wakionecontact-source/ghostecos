// Бегущая строка для длинных имён (шапка чата) — фейд по краям + пауза на
// обоих концах. Текст стартует/останавливается СО СДВИГОМ на ширину фейда
// (_fade), а не от нуля — иначе первая/последняя буква попадают под градиент
// и выглядят притушенными (баг, который поймал waki на первом мокапе).
// Вперёд/назад зеркально одинаковы "бесплатно": обе фазы читают одну и ту же
// curved-функцию от _ctrl.value, а не отдельные keyframe-наборы как в CSS.
import 'dart:async';
import 'package:flutter/material.dart';

class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const MarqueeText({super.key, required this.text, required this.style});

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  static const _fade = 18.0;
  static const _pause = Duration(seconds: 5);

  late final AnimationController _ctrl;
  Timer? _timer;
  double _shift = 0;
  bool _overflowing = false;
  String? _measuredFor;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3500),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _measure(double maxWidth) {
    if (!maxWidth.isFinite || maxWidth <= 0) return;
    final key = '${widget.text}|$maxWidth';
    if (_measuredFor == key) return;
    _measuredFor = key;
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final overflow = tp.width - maxWidth;
    _timer?.cancel();
    _ctrl.stop();
    _ctrl.value = 0;
    if (overflow <= 0) {
      _overflowing = false;
      return;
    }
    _overflowing = true;
    _shift = overflow + 2 * _fade;
    _scheduleLoop();
  }

  void _scheduleLoop() {
    _timer = Timer(_pause, () async {
      if (!mounted) return;
      await _ctrl.forward();
      if (!mounted) return;
      _timer = Timer(_pause, () async {
        if (!mounted) return;
        await _ctrl.reverse();
        if (!mounted) return;
        _scheduleLoop();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _measure(constraints.maxWidth);
        if (!_overflowing) {
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        final w = constraints.maxWidth;
        final stopFrac = w > 0 ? (_fade / w).clamp(0.0, 0.5) : 0.0;
        return SizedBox(
          width: w,
          child: ClipRect(
            child: ShaderMask(
              shaderCallback: (rect) => LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: const [
                  Colors.transparent,
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                ],
                stops: [0.0, stopFrac, 1 - stopFrac, 1.0],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: OverflowBox(
                maxWidth: double.infinity,
                alignment: Alignment.centerLeft,
                child: AnimatedBuilder(
                  animation: _ctrl,
                  builder: (context, _) {
                    final curved = Curves.easeInOutCubic.transform(_ctrl.value);
                    final dx = _fade - curved * _shift;
                    return Transform.translate(
                      offset: Offset(dx, 0),
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.visible,
                        style: widget.style,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
