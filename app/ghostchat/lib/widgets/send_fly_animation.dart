// "Отправка" — маленький бабл вылетает из кнопки-самолётика в сторону ленты
// и тает. Чисто декоративный оверлей поверх текущего экрана: не завязан на
// реальную позицию новой баблы в списке (синхронизировать координаты с
// анимированным списком, клавиатурой и скроллом — хрупко), только вылет из
// точки нажатия. Кривая — "замедленный куб" (уже на экране, просто уезжает
// и тает), по CapCut-словарю анимаций проекта.
import 'package:flutter/material.dart';
import '../theme.dart';

void flySendAnimation(BuildContext context, GlobalKey buttonKey) {
  final renderBox =
      buttonKey.currentContext?.findRenderObject() as RenderBox?;
  if (renderBox == null || !renderBox.attached) return;
  final overlay = Overlay.of(context, rootOverlay: true);
  final origin = renderBox.localToGlobal(renderBox.size.center(Offset.zero));
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _FlyingBubble(origin: origin, onDone: () => entry.remove()),
  );
  overlay.insert(entry);
}

class _FlyingBubble extends StatefulWidget {
  final Offset origin;
  final VoidCallback onDone;
  const _FlyingBubble({required this.origin, required this.onDone});

  @override
  State<_FlyingBubble> createState() => _FlyingBubbleState();
}

class _FlyingBubbleState extends State<_FlyingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..forward().whenComplete(widget.onDone);
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
      builder: (context, _) {
        final t = Curves.easeInOutCubic.transform(_ctrl.value);
        final dx = -34.0 * t;
        final dy = -46.0 * t;
        final scale = 1.0 - 0.5 * t;
        final opacity = (1 - t).clamp(0.0, 1.0);
        return Positioned(
          left: widget.origin.dx - 9 + dx,
          top: widget.origin.dy - 9 + dy,
          child: IgnorePointer(
            child: Opacity(
              opacity: opacity,
              child: Transform.scale(
                scale: scale,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
