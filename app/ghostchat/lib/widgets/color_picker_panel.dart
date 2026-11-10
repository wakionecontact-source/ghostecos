// Полноценный цветовой пикер с HSV-выбором — без внешних зависимостей.
// Перенесён из ghostchat_mobile (1.19.3), адаптирован под GE-палитру.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Публичный виджет
// ─────────────────────────────────────────────────────────────────────────────

class ColorPickerPanel extends StatefulWidget {
  /// Начальный цвет
  final Color initial;
  /// Вызывается при выборе цвета (live preview)
  final ValueChanged<Color> onChanged;
  /// Подпись
  final String label;

  const ColorPickerPanel({
    super.key,
    required this.initial,
    required this.onChanged,
    this.label = '',
  });

  @override
  State<ColorPickerPanel> createState() => _ColorPickerPanelState();
}

class _ColorPickerPanelState extends State<ColorPickerPanel> {
  late HSVColor _hsv;
  late TextEditingController _hexCtrl;
  bool _editingHex = false;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
    _hexCtrl = TextEditingController(text: _colorToHex(widget.initial));
  }

  @override
  void didUpdateWidget(covariant ColorPickerPanel old) {
    super.didUpdateWidget(old);
    // Родитель сменил initial (напр. кнопка "Сбросить") — синхронизируемся.
    if (old.initial != widget.initial && widget.initial != _hsv.toColor()) {
      _hsv = HSVColor.fromColor(widget.initial);
      _hexCtrl.text = _colorToHex(widget.initial);
    }
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  Color get _color => _hsv.toColor();

  String _colorToHex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  void _setHsv(HSVColor v) {
    setState(() => _hsv = v);
    if (!_editingHex) _hexCtrl.text = _colorToHex(v.toColor());
    widget.onChanged(v.toColor());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(widget.label,
                style: TextStyle(
                    color: GE.sub,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8)),
          ),
        // ── SV квадрат ────────────────────────────────────────────────────
        _SvSquare(
          hue: _hsv.hue,
          sat: _hsv.saturation,
          val: _hsv.value,
          onChanged: (s, v) => _setHsv(_hsv.withSaturation(s).withValue(v)),
        ),
        const SizedBox(height: 10),
        // ── Hue-слайдер ──────────────────────────────────────────────────
        _HueSlider(
          hue: _hsv.hue,
          onChanged: (h) => _setHsv(_hsv.withHue(h)),
        ),
        const SizedBox(height: 12),
        // ── HEX-поле + превью ─────────────────────────────────────────────
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: GE.border),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _hexCtrl,
                style: TextStyle(
                    color: GE.text, fontSize: 14, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  hintText: '#RRGGBB',
                  hintStyle: TextStyle(color: GE.sub),
                  filled: true,
                  fillColor: GE.glassFill,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: GE.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: GE.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: GE.primary, width: 1.5),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  isDense: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F#]')),
                  LengthLimitingTextInputFormatter(9),
                ],
                onTap: () => _editingHex = true,
                onSubmitted: (v) {
                  _editingHex = false;
                  final hex = v.replaceAll('#', '');
                  try {
                    if (hex.length == 6) {
                      // Без альфы — сохраняем текущую прозрачность поля
                      // вместо того, чтобы молча делать его непрозрачным.
                      final rgb = Color(int.parse('FF$hex', radix: 16));
                      final c = rgb.withValues(alpha: _hsv.alpha);
                      _setHsv(HSVColor.fromColor(c));
                    } else if (hex.length == 8) {
                      final c = Color(int.parse(hex, radix: 16));
                      _setHsv(HSVColor.fromColor(c));
                    }
                  } catch (_) {}
                },
                onEditingComplete: () => _editingHex = false,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SV квадрат
// ─────────────────────────────────────────────────────────────────────────────

class _SvSquare extends StatelessWidget {
  final double hue, sat, val;
  final void Function(double s, double v) onChanged;

  const _SvSquare({
    required this.hue,
    required this.sat,
    required this.val,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final size = box.maxWidth;
      final h = size * 0.6;
      return GestureDetector(
        onPanUpdate: (d) {
          final dx = (d.localPosition.dx / size).clamp(0.0, 1.0);
          final dy = (d.localPosition.dy / h).clamp(0.0, 1.0);
          onChanged(dx, 1.0 - dy);
        },
        onTapDown: (d) {
          final dx = (d.localPosition.dx / size).clamp(0.0, 1.0);
          final dy = (d.localPosition.dy / h).clamp(0.0, 1.0);
          onChanged(dx, 1.0 - dy);
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: size,
            height: h,
            child: CustomPaint(
              painter: _SvPainter(hue: hue, sat: sat, val: val),
            ),
          ),
        ),
      );
    });
  }
}

class _SvPainter extends CustomPainter {
  final double hue, sat, val;
  _SvPainter({required this.hue, required this.sat, required this.val});

  @override
  void paint(Canvas canvas, Size sz) {
    final rect = Offset.zero & sz;
    // Фон: чистый цвет (S=1,V=1)
    final baseColor = HSVColor.fromAHSV(1, hue, 1, 1).toColor();
    // Горизонтальный градиент: белый → цвет
    final hGrad = LinearGradient(colors: [GE.text, baseColor]);
    // Вертикальный градиент: прозрачный → чёрный
    final vGrad = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, GE.shadow]);

    canvas.drawRect(rect, Paint()..shader = hGrad.createShader(rect));
    canvas.drawRect(rect, Paint()..shader = vGrad.createShader(rect));

    // Курсор
    final cx = sat * sz.width;
    final cy = (1 - val) * sz.height;
    canvas.drawCircle(
        Offset(cx, cy),
        8,
        Paint()
          ..color = GE.text
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    canvas.drawCircle(Offset(cx, cy), 6,
        Paint()..color = HSVColor.fromAHSV(1, hue, sat, val).toColor());
  }

  @override
  bool shouldRepaint(_SvPainter o) =>
      o.hue != hue || o.sat != sat || o.val != val;
}

// ─────────────────────────────────────────────────────────────────────────────
// Hue слайдер
// ─────────────────────────────────────────────────────────────────────────────

class _HueSlider extends StatelessWidget {
  final double hue;
  final ValueChanged<double> onChanged;

  const _HueSlider({required this.hue, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final w = box.maxWidth;
      const h = 18.0;
      return GestureDetector(
        onPanUpdate: (d) =>
            onChanged((d.localPosition.dx / w * 360).clamp(0, 360)),
        onTapDown: (d) =>
            onChanged((d.localPosition.dx / w * 360).clamp(0, 360)),
        child: SizedBox(
          width: w,
          height: h,
          child: CustomPaint(painter: _HuePainter(hue: hue)),
        ),
      );
    });
  }
}

class _HuePainter extends CustomPainter {
  final double hue;
  _HuePainter({required this.hue});

  @override
  void paint(Canvas canvas, Size sz) {
    final rect = Offset.zero & sz;
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(sz.height / 2));

    // Радуга
    final colors =
        List.generate(7, (i) => HSVColor.fromAHSV(1, i * 60.0, 1, 1).toColor());
    canvas.drawRRect(
        rr, Paint()..shader = LinearGradient(colors: colors).createShader(rect));

    // Ползунок
    final cx = hue / 360 * sz.width;
    canvas.drawCircle(
        Offset(cx, sz.height / 2),
        sz.height / 2 + 1,
        Paint()
          ..color = GE.text
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    canvas.drawCircle(Offset(cx, sz.height / 2), sz.height / 2 - 2,
        Paint()..color = HSVColor.fromAHSV(1, hue, 1, 1).toColor());
  }

  @override
  bool shouldRepaint(_HuePainter o) => o.hue != hue;
}
