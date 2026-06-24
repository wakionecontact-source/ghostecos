// LanScanScreen — «Чаты по сети (LAN)». ПОКА ЗАГЛУШКА.
//
// Никакого реального сетевого сканирования здесь нет — только UI:
//   • анимация «радара» (пульсирующие круги + бегущий луч) через
//     AnimationController + AnimatedBuilder, БЕЗ внешних пакетов;
//   • пустой список-плейсхолдер «устройства не найдены»;
//   • поясняющая карточка простым языком — что это за будущая фича;
//   • кнопка «Обновить» — просто перезапускает анимацию сканирования.
//
// Будущая фича: общаться напрямую по локальной сети (один Wi-Fi / точка),
// без интернета и без сервера.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';

class LanScanScreen extends StatefulWidget {
  const LanScanScreen({super.key});
  @override
  State<LanScanScreen> createState() => _LanScanScreenState();
}

class _LanScanScreenState extends State<LanScanScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  // true — идёт «поиск» (крутится радар), false — «поиск завершён, пусто».
  bool _scanning = true;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    // Через пару секунд «сканирование» завершается — но ничего не находим
    // (это заглушка). Анимация продолжает мягко пульсировать.
    _scheduleFinish();
  }

  void _scheduleFinish() {
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _scanning = false);
    });
  }

  // Кнопка «Обновить» — перезапускаем анимацию и снова «ищем».
  void _restart() {
    if (!mounted) return;
    setState(() => _scanning = true);
    _ctrl
      ..reset()
      ..repeat();
    _scheduleFinish();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(child: _scaffold(context));
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: GlassAppBar(showBack: true, titleText: 'Чаты по сети'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          const SizedBox(height: 12),
          _radar(),
          const SizedBox(height: 18),
          Text(
            _scanning ? 'Ищем устройства поблизости…' : 'Пока никого не нашли',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: GE.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _scanning
                ? 'Смотрим, кто рядом в этой же сети Wi-Fi.'
                : 'Эта функция ещё готовится — реального поиска пока нет.',
            textAlign: TextAlign.center,
            style: TextStyle(color: GE.sub, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 22),
          _emptyList(),
          const SizedBox(height: 18),
          Center(
            child: GlassButton(
              label: 'Обновить',
              icon: Icons.refresh,
              onTap: _restart,
            ),
          ),
          const SizedBox(height: 22),
          _infoCard(),
          const SizedBox(height: 12),
          _soonCard(),
        ],
      ),
    );
  }

  // ── Анимация радара ───────────────────────────────────────────────────
  Widget _radar() {
    return Center(
      child: SizedBox(
        width: 200,
        height: 200,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) {
            return CustomPaint(
              painter: _RadarPainter(
                progress: _ctrl.value,
                color: GE.primary,
                scanning: _scanning,
              ),
              child: Center(
                child: Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: GE.primary.withValues(alpha: 0.18),
                    border: Border.all(color: GE.primary, width: 1.4),
                  ),
                  child: Icon(
                    _scanning ? Icons.wifi_tethering : Icons.wifi_find,
                    color: GE.primary,
                    size: 26,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ── Пустой список-плейсхолдер ─────────────────────────────────────────
  Widget _emptyList() {
    return GlassCard(
      lite: true,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
      child: Column(
        children: [
          Icon(Icons.devices_other, color: GE.sub, size: 30),
          const SizedBox(height: 10),
          Text(
            'Устройства не найдены',
            style: TextStyle(
              color: GE.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Когда рядом появится кто-то с приложением,\nон покажется в этом списке.',
            textAlign: TextAlign.center,
            style: TextStyle(color: GE.sub, fontSize: 11, height: 1.4),
          ),
        ],
      ),
    );
  }

  // ── Поясняющая карточка про фичу ──────────────────────────────────────
  Widget _infoCard() {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lan_outlined, color: GE.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Что это такое',
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Чаты по сети — это общение напрямую с теми, кто рядом, по локальной '
            'сети (один Wi-Fi или общая точка доступа). Сообщения идут между '
            'устройствами без интернета и без сервера.',
            style: TextStyle(color: GE.sub, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 12),
          _bullet(Icons.wifi_off, 'Работает без интернета — нужна только общая сеть'),
          _bullet(Icons.bolt, 'Быстро: данные не уходят за пределы вашей сети'),
          _bullet(Icons.lock_outline, 'Меньше посредников — меньше следов'),
        ],
      ),
    );
  }

  Widget _bullet(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: GE.primary, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: GE.sub, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  // ── Карточка «скоро» ──────────────────────────────────────────────────
  Widget _soonCard() {
    return GlassCard(
      lite: true,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: GE.yellow.withValues(alpha: 0.16),
              border: Border.all(color: GE.yellow, width: 1),
            ),
            child: Icon(Icons.hourglass_empty, color: GE.yellow, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Функция готовится',
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Сейчас это только превью внешнего вида. Поиск устройств '
                  'появится в одном из обновлений.',
                  style: TextStyle(color: GE.sub, fontSize: 11, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Художник радара ───────────────────────────────────────────────────
class _RadarPainter extends CustomPainter {
  final double progress; // 0..1
  final Color color;
  final bool scanning;

  _RadarPainter({
    required this.progress,
    required this.color,
    required this.scanning,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;

    // Статичные кольца-сетка.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.18);
    for (var i = 1; i <= 3; i++) {
      canvas.drawCircle(center, maxR * i / 3, ring);
    }

    // Пульсирующие волны (несколько, со сдвигом по фазе).
    const waves = 3;
    for (var i = 0; i < waves; i++) {
      final t = (progress + i / waves) % 1.0;
      final r = maxR * t;
      final alpha = (1 - t) * (scanning ? 0.45 : 0.22);
      if (alpha <= 0) continue;
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = color.withValues(alpha: alpha),
      );
    }

    // Бегущий луч-сектор — только во время «сканирования».
    if (scanning) {
      final sweepStart = progress * 2 * math.pi;
      const sweepWidth = math.pi / 3; // 60°
      final rect = Rect.fromCircle(center: center, radius: maxR);
      final sweep = Paint()
        ..shader = SweepGradient(
          startAngle: sweepStart,
          endAngle: sweepStart + sweepWidth,
          colors: [
            color.withValues(alpha: 0.0),
            color.withValues(alpha: 0.35),
          ],
          stops: const [0.0, 1.0],
          transform: GradientRotation(0),
        ).createShader(rect);
      canvas.drawArc(rect, sweepStart, sweepWidth, true, sweep);
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.progress != progress ||
      old.scanning != scanning ||
      old.color != color;
}
