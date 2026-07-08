// Выбор режима хранения E2E-ключа — шаг онбординга (после разрешений).
// server — зашифрованный паролем приватник лежит на сервере (переживает
// переустановку, нужен пароль). local — ключ только на устройстве (приватнее,
// но переустановка = потеря переписки). Сохраняется в pref key_storage_mode и
// применяется при регистрации/синхронизации (см. ChatRepo.syncKeys).
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';

class KeyChoiceScreen extends StatefulWidget {
  final VoidCallback onDone;
  const KeyChoiceScreen({super.key, required this.onDone});

  @override
  State<KeyChoiceScreen> createState() => _KeyChoiceScreenState();
}

class _KeyChoiceScreenState extends State<KeyChoiceScreen> {
  String _mode = 'server'; // по умолчанию — рекомендуемый

  Future<void> _finish() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('key_storage_mode', _mode);
    await p.setBool('keychoice_done', true);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 24),
                Icon(Icons.key_outlined, size: 52, color: GE.primary),
                const SizedBox(height: 14),
                Text(
                  'Ключ шифрования',
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Сообщения шифруются ключом, который есть только у тебя. Что с '
                  'ним делать при переустановке или смене устройства?',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GE.sub, fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 22),
                _option(
                  mode: 'server',
                  icon: Icons.cloud_done_outlined,
                  title: 'Облачный бэкап',
                  badge: 'Рекомендуется',
                  body:
                      'Ключ, зашифрованный твоим паролем, хранится на сервере. '
                      'Переустановил → ввёл пароль → переписка на месте. Сервер '
                      'сам ключ прочитать НЕ может.',
                ),
                const SizedBox(height: 12),
                _option(
                  mode: 'local',
                  icon: Icons.phonelink_lock_outlined,
                  title: 'Только на устройстве',
                  body:
                      'Максимум приватности: ключ никогда не покидает телефон. '
                      'Но при переустановке или смене устройства переписка '
                      'теряется безвозвратно.',
                ),
                const Spacer(),
                GlassButton(
                  label: 'Далее',
                  icon: Icons.arrow_forward,
                  primary: true,
                  fullWidth: true,
                  onTap: _finish,
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _option({
    required String mode,
    required IconData icon,
    required String title,
    String? badge,
    required String body,
  }) {
    final sel = _mode == mode;
    return GestureDetector(
      onTap: () => setState(() => _mode = mode),
      child: GlassCard(
        glow: sel,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: sel ? GE.primary : GE.sub, size: 22),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: GE.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (badge != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: GE.primary.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      badge,
                      style: TextStyle(
                        color: GE.primary,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                Icon(
                  sel
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: sel ? GE.primary : GE.sub,
                  size: 20,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: TextStyle(color: GE.sub, fontSize: 12.5, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
