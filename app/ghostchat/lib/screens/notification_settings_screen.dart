// Настройки → Уведомления — перенесено из 1.19.3 (там же структура):
// общий тумблер + "исключения" (замьюченные чаты) + отдельно "Внутренние
// уведомления" (in-app toast) с тумблерами по уровням.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../services/notification_settings.dart';
import '../services/theme_service.dart';
import '../widgets/glass.dart';
import 'chat_picker_screen.dart';

class NotificationSettingsScreen extends StatelessWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ns = NotificationSettings.instance;
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(showBack: true, titleText: 'Уведомления'),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Push-уведомления',
              style: TextStyle(
                color: GE.text,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            GlassCard(
              isListSection: true,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: ValueListenableBuilder<bool>(
                valueListenable: ns.enabledNotifier,
                builder: (context, enabled, _) {
                  return Column(
                    children: [
                      _switchRow(
                        'Уведомления',
                        'О новых сообщениях, пока приложение живо',
                        enabled,
                        ns.setEnabled,
                      ),
                      if (enabled) ...[
                        Divider(height: 1, color: GE.glassBorder, indent: 14),
                        ValueListenableBuilder<Set<String>>(
                          valueListenable: ns.mutedPeersNotifier,
                          builder: (context, muted, _) => _tapRow(
                            context,
                            CupertinoIcons.bell_slash,
                            'Исключения',
                            'Чатов без уведомлений: ${muted.length}',
                            () => _openExceptionsSheet(context),
                          ),
                        ),
                        Divider(height: 1, color: GE.glassBorder, indent: 14),
                        ValueListenableBuilder<bool>(
                          valueListenable: ns.showSenderNotifier,
                          builder: (context, value, _) => _switchRow(
                            'Показывать имя отправителя',
                            'Имя или ник будет виден в заголовке уведомления',
                            value,
                            ns.setShowSender,
                          ),
                        ),
                        Divider(height: 1, color: GE.glassBorder, indent: 14),
                        ValueListenableBuilder<bool>(
                          valueListenable: ns.showContentNotifier,
                          builder: (context, value, _) => _switchRow(
                            'Показывать содержание сообщения',
                            'Текст сообщения будет виден в уведомлении',
                            value,
                            ns.setShowContent,
                          ),
                        ),
                        Divider(height: 1, color: GE.glassBorder, indent: 14),
                        ValueListenableBuilder<bool>(
                          valueListenable: ns.showMediaPreviewNotifier,
                          builder: (context, value, _) => _switchRow(
                            'Показывать фото в уведомлениях',
                            'Миниатюра фото может быть видна на заблокированном экране',
                            value,
                            ns.setShowMediaPreview,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Внутренние уведомления',
              style: TextStyle(
                color: GE.text,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            if (ThemeService.instance.showDetailedDescriptions)
              Text(
                'Всплывающие тосты внутри приложения (не системный push) — ошибки, предупреждения, информационные сообщения.',
                style: TextStyle(color: GE.sub, fontSize: 12, height: 1.4),
              ),
            const SizedBox(height: 8),
            GlassCard(
              isListSection: true,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: ValueListenableBuilder<bool>(
                valueListenable: ns.toastEnabledNotifier,
                builder: (context, toastEnabled, _) {
                  return Column(
                    children: [
                      _switchRow(
                        'Показывать тосты',
                        null,
                        toastEnabled,
                        ns.setToastEnabled,
                      ),
                      if (toastEnabled) ...[
                        Divider(height: 1, color: GE.glassBorder, indent: 14),
                        ValueListenableBuilder<bool>(
                          valueListenable: ns.toastShowErrorsNotifier,
                          builder: (context, v, _) => _switchRow(
                            'Ошибки',
                            null,
                            v,
                            ns.setToastShowErrors,
                          ),
                        ),
                        Divider(height: 1, color: GE.glassBorder, indent: 14),
                        ValueListenableBuilder<bool>(
                          valueListenable: ns.toastShowWarningsNotifier,
                          builder: (context, v, _) => _switchRow(
                            'Предупреждения',
                            null,
                            v,
                            ns.setToastShowWarnings,
                          ),
                        ),
                        Divider(height: 1, color: GE.glassBorder, indent: 14),
                        ValueListenableBuilder<bool>(
                          valueListenable: ns.toastShowInfoNotifier,
                          builder: (context, v, _) => _switchRow(
                            'Информационные',
                            null,
                            v,
                            ns.setToastShowInfo,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _switchRow(
    String title,
    String? sub,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (sub != null &&
                    ThemeService.instance.showDetailedDescriptions) ...[
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(color: GE.sub, fontSize: 11.5)),
                ],
              ],
            ),
          ),
          GhostSwitch(
            value: value,
            activeColor: GE.primary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _tapRow(
    BuildContext context,
    IconData icon,
    String title,
    String sub,
    VoidCallback onTap,
  ) {
    return PressScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: GE.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: GE.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(color: GE.sub, fontSize: 11.5)),
                ],
              ),
            ),
            Icon(CupertinoIcons.chevron_right, color: GE.sub, size: 20),
          ],
        ),
      ),
    );
  }

  Future<void> _openExceptionsSheet(BuildContext context) async {
    final ns = NotificationSettings.instance;
    final result = await Navigator.of(context).push<Set<String>>(
      MaterialPageRoute(
        builder: (_) => ChatPickerScreen(
          initialSelected: ns.mutedPeersNotifier.value,
          title: 'Без уведомлений',
        ),
      ),
    );
    if (result == null) return;
    final before = ns.mutedPeersNotifier.value;
    for (final u in result.difference(before)) {
      ns.setMuted(u, true);
    }
    for (final u in before.difference(result)) {
      ns.setMuted(u, false);
    }
  }
}
