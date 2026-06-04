// Settings — настройки приложения. Сейчас: переключатель темы (5 пресетов
// + светлая). Дальше M8: паник-пароль, экспорт ключей, диктофон фон, био-логин.

import 'package:flutter/material.dart';
import '../theme.dart';
import '../services/chat_repo.dart';
import '../services/theme_service.dart';
import '../widgets/glass.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: GlassAppBar(
        showBack: true,
        titleText: 'Настройки',
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _sectionTitle('Внешний вид'),
          _ThemeGrid(),
          const SizedBox(height: 20),
          _sectionTitle('Звук и уведомления'),
          GlassCard(
            child: Column(
              children: [
                _switchRow(Icons.notifications_active_outlined,
                    'Системные уведомления', true, (_) {}),
                _switchRow(Icons.volume_up_outlined,
                    'Звук сообщений', true, (_) {}),
                _switchRow(Icons.vibration,
                    'Вибрация', true, (_) {}),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle('Приватность'),
          GlassCard(
            child: Column(
              children: [
                _switchRow(Icons.lock_clock_outlined,
                    'Auto-lock через 5 мин (готовится)', false, (_) {}),
                _switchRow(Icons.shield_outlined,
                    'Скрыть превью в шторке', true, (_) {}),
                _switchRow(Icons.no_photography_outlined,
                    'Запретить скриншоты (готовится)', false, (_) {}),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle('Чат'),
          GlassCard(
            child: Column(
              children: [
                _switchRow(Icons.image_outlined,
                    'Авто-загрузка картинок в Wi-Fi', true, (_) {}),
                _switchRow(Icons.mic_external_on,
                    'Авто-воспроизведение голосовых', false, (_) {}),
                _switchRow(Icons.read_more,
                    'Read-реситы (двойная галка)', true, (_) {}),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle('Безопасность'),
          GlassCard(
            child: Column(
              children: [
                _tile(Icons.vpn_key_outlined, 'Экспорт seed-фразы', () {}),
                _tile(Icons.fingerprint, 'Био-логин (готовится)', () {}),
                _tile(Icons.password, 'Паник-пароль (готовится)', () {}),
                _tile(Icons.devices_other,
                    'Сессии и устройства (готовится)', () {}),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle('E2E ключи'),
          GlassCard(
            child: Column(
              children: [
                _tile(Icons.upload_outlined,
                    'Перезалить мой ключ на сервер', _forcePublishKey,
                    sub: 'Используй если пиры пишут «не удалось расшифровать»'),
                _tile(Icons.refresh, 'Перегенерировать E2E-пару',
                    () => _confirmRegenerate(context),
                    sub: 'NUCLEAR: новый приват, всю старую переписку нельзя расшифровать',
                    danger: true),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle('О приложении'),
          GlassCard(
            child: Column(
              children: [
                _tile(Icons.info_outline, 'Ghost · v0.2.0', () {}),
                _tile(Icons.code, 'Открытый исходник на GitHub', () {}),
                _tile(Icons.help_outline, 'Помощь', () {}),
              ],
            ),
          ),
          const SizedBox(height: 60),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                color: GE.sub, fontSize: 11, fontWeight: FontWeight.w700,
                letterSpacing: 0.5)),
      );

  Widget _switchRow(IconData icon, String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: GE.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: TextStyle(color: GE.text, fontSize: 14))),
          Switch(value: value, onChanged: onChanged, activeThumbColor: GE.primary),
        ],
      ),
    );
  }

  Widget _tile(IconData icon, String label, VoidCallback onTap,
      {String? sub, bool danger = false}) {
    final color = danger ? GE.red : GE.primary;
    final textColor = danger ? GE.red : GE.text;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(color: textColor, fontSize: 14)),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(sub,
                        style: TextStyle(color: GE.sub, fontSize: 11)),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: GE.sub, size: 20),
          ],
        ),
      ),
    );
  }

  Future<void> _forcePublishKey() async {
    _snack('Заливаю ключ на сервер...');
    final res = await ChatRepo.instance.forcePublishMyPubKey();
    _snack(res);
  }

  Future<void> _confirmRegenerate(BuildContext ctx) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: Text('Перегенерировать E2E-пару?',
            style: TextStyle(color: GE.text)),
        content: Text(
          'ВНИМАНИЕ: будет создан новый приватный ключ. Все ранее присланные '
          'тебе сообщения, зашифрованные старым публичным ключом, СТАНУТ '
          'нечитаемыми. Делать ТОЛЬКО если ничего больше не помогает.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text('Перегенерировать', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _snack('Генерирую новый ключ...');
    final res = await ChatRepo.instance.regenerateKeys();
    _snack(res);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
class _ThemeGrid extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final presets = ThemeService.instance.presets;
    final current = ThemeService.instance.notifier.value;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.5,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: presets.length,
      itemBuilder: (_, i) {
        final p = presets[i];
        final active = p.id == current.id;
        return InkWell(
          borderRadius: BorderRadius.circular(GE.radiusMd),
          onTap: () async {
            await ThemeService.instance.setPreset(p.id);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [p.bg, p.bgDeep],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(GE.radiusMd),
              border: Border.all(
                color: active ? p.primary : Colors.white.withValues(alpha: 0.1),
                width: active ? 2 : 1,
              ),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: p.primary.withValues(alpha: 0.4),
                        blurRadius: 18,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 18, height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: [p.primary, p.primary2]),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 12, height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: p.green,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Container(
                      width: 12, height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: p.yellow,
                      ),
                    ),
                    const Spacer(),
                    if (active)
                      Icon(Icons.check_circle, color: p.primary, size: 18),
                  ],
                ),
                const Spacer(),
                Text(p.name,
                    style: TextStyle(
                        color: p.text, fontSize: 14, fontWeight: FontWeight.w700)),
                Text(p.subtitle,
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.text.withValues(alpha: 0.65), fontSize: 11)),
              ],
            ),
          ),
        );
      },
    );
  }
}
