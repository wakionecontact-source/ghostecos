// PreparingScreen — короткий персонализированный экран между входом/
// регистрацией и самим приложением. Показывается один раз сразу после
// AuthScreen (не на каждом холодном старте с уже сохранённым токеном).
import 'dart:async';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../services/auth_service.dart';

const _messages = <String>[
  'Раскладываем чаты по местам…',
  'Ваш ключ шифрования не покидает это устройство.',
  'Даже мы не знаем, о чём вы переписываетесь. И не хотим.',
  'LAN-чаты работают вообще без интернета — просто по Wi-Fi.',
  'Ищем призраков поблизости…',
  'Обычно это быстрее, чем кажется.',
];

class PreparingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const PreparingScreen({super.key, required this.onDone});

  @override
  State<PreparingScreen> createState() => _PreparingScreenState();
}

class _PreparingScreenState extends State<PreparingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bar;
  String _name = '';
  int _msgIndex = 0;
  Timer? _msgTimer;
  Timer? _doneTimer;

  @override
  void initState() {
    super.initState();
    _bar = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _load();

    _msgTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (!mounted) return;
      setState(() => _msgIndex = (_msgIndex + 1) % _messages.length);
    });
    _doneTimer = Timer(const Duration(milliseconds: 2900), () {
      if (mounted) widget.onDone();
    });
  }

  Future<void> _load() async {
    final display = await AuthService.displayName();
    final user = await AuthService.username();
    final name = (display != null && display.trim().isNotEmpty)
        ? display.trim()
        : (user ?? '');
    if (!mounted) return;
    setState(() => _name = name);
  }

  @override
  void dispose() {
    _bar.dispose();
    _msgTimer?.cancel();
    _doneTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _name.isEmpty ? 'Привет!' : 'Привет, $_name!',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: GE.text,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Мы готовим для вас приложение, подождите',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: GE.sub, fontSize: 14, height: 1.4),
                  ),
                  const SizedBox(height: 36),
                  _lineLoader(),
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 34,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      child: Text(
                        _messages[_msgIndex],
                        key: ValueKey(_msgIndex),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: GE.sub, fontSize: 12.5, height: 1.4),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Тонкая линия-трек с ярким сегментом, который ходит туда-сюда.
  Widget _lineLoader() {
    return SizedBox(
      width: 140,
      height: 4,
      child: AnimatedBuilder(
        animation: _bar,
        builder: (context, _) {
          return Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: GE.glassBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              LayoutBuilder(
                builder: (context, c) {
                  const segment = 46.0;
                  final travel = c.maxWidth - segment;
                  final x = travel * Curves.easeInOut.transform(_bar.value);
                  return Transform.translate(
                    offset: Offset(x, 0),
                    child: Container(
                      width: segment,
                      height: 4,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        gradient: LinearGradient(
                          colors: [
                            GE.primary.withValues(alpha: 0),
                            GE.primary,
                            GE.blue,
                            GE.primary.withValues(alpha: 0),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: GE.primary.withValues(alpha: 0.6),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
