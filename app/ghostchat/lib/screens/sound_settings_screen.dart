import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../mesh_background.dart';
import '../services/ghost_sound_effects.dart';
import '../services/ghost_sound_waveforms.dart';
import '../services/notification_service.dart';
import '../services/sound_settings.dart';
import '../services/theme_service.dart';
import '../theme.dart';
import '../widgets/glass.dart';

class SoundSettingsScreen extends StatelessWidget {
  const SoundSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final soundSettings = SoundSettings.instance;
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(showBack: true, titleText: 'Звуки'),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Звуки GhostChat',
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
              child: Column(
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: soundSettings.uiSoundsEnabledNotifier,
                    builder: (context, enabled, _) => _switchRow(
                      'Звуки нажатий',
                      'Короткие фирменные отклики кнопок и переключателей',
                      enabled,
                      soundSettings.setUiSoundsEnabled,
                    ),
                  ),
                  _tapVariantSelector(soundSettings),
                  Divider(height: 1, color: GE.glassBorder, indent: 14),
                  ValueListenableBuilder<bool>(
                    valueListenable:
                        soundSettings.notificationSoundsEnabledNotifier,
                    builder: (context, enabled, _) => _switchRow(
                      'Звуки уведомлений',
                      'Фирменный сигнал сообщений и предупреждений',
                      enabled,
                      soundSettings.setNotificationSoundsEnabled,
                    ),
                  ),
                  _effectVariantSelector(
                    title: 'Новые сообщения',
                    variants: const ['Мягкий', 'Мелодичный', 'Яркий'],
                    selected: soundSettings.notificationVariantNotifier,
                    onSelected: soundSettings.setNotificationVariant,
                    onPreview:
                        GhostSoundEffects.instance.previewNotificationVariant,
                  ),
                  _effectVariantSelector(
                    title: 'Входящий звонок',
                    variants: const ['Ретро', 'Ритмичный', 'Мягкий'],
                    selected: soundSettings.callVariantNotifier,
                    onSelected: soundSettings.setCallVariant,
                    onPreview: GhostSoundEffects.instance.previewCallVariant,
                  ),
                  _effectVariantSelector(
                    title: 'Успешное действие',
                    variants: const ['Лёгкий', 'Радостный', 'Искры'],
                    selected: soundSettings.successVariantNotifier,
                    onSelected: soundSettings.setSuccessVariant,
                    onPreview: GhostSoundEffects.instance.previewSuccessVariant,
                  ),
                  _effectVariantSelector(
                    title: 'Предупреждение',
                    variants: const ['Спокойный', 'Пульс', 'Сигнал'],
                    selected: soundSettings.warningVariantNotifier,
                    onSelected: soundSettings.setWarningVariant,
                    onPreview: GhostSoundEffects.instance.previewWarningVariant,
                  ),
                  _effectVariantSelector(
                    title: 'Ошибка',
                    variants: const ['Спокойная', 'Резкая', 'Низкая'],
                    selected: soundSettings.errorVariantNotifier,
                    onSelected: soundSettings.setErrorVariant,
                    onPreview: GhostSoundEffects.instance.previewErrorVariant,
                  ),
                  Divider(height: 1, color: GE.glassBorder, indent: 14),
                  _tapRow(
                    context,
                    CupertinoIcons.speaker_2,
                    'Прослушать сигнал',
                    'Воспроизвести мелодию GhostChat',
                    () => unawaited(
                      GhostSoundEffects.instance.previewNotification(),
                    ),
                  ),
                  Divider(height: 1, color: GE.glassBorder, indent: 14),
                  _tapRow(
                    context,
                    CupertinoIcons.bell,
                    'Проверить уведомление',
                    'Системный режим «Без звука» влияет на это уведомление',
                    () => unawaited(
                      NotificationService.instance.showSoundTestNotification(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tapVariantSelector(SoundSettings settings) {
    const variants = GhostSoundWaveforms.tapVariantNames;
    return ValueListenableBuilder<int>(
      valueListenable: settings.uiTapVariantNotifier,
      builder: (context, selected, _) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '10 разных звуков · нажмите для прослушивания',
              style: TextStyle(color: GE.sub, fontSize: 11.5),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: List.generate(variants.length, (index) {
                final isSelected = selected == index;
                return Semantics(
                  button: true,
                  selected: isSelected,
                  label: 'Звук нажатия ${index + 1}: ${variants[index]}',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      unawaited(settings.setUiTapVariant(index));
                      unawaited(
                        GhostSoundEffects.instance.previewTapVariant(index),
                      );
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 11),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? GE.primary.withValues(alpha: 0.16)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(
                          color: isSelected ? GE.primary : GE.glassBorder,
                        ),
                      ),
                      child: Text(
                        '${index + 1} · ${variants[index]}',
                        style: TextStyle(
                          color: isSelected ? GE.primary : GE.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _effectVariantSelector({
    required String title,
    required List<String> variants,
    required ValueListenable<int> selected,
    required Future<void> Function(int) onSelected,
    required Future<void> Function(int) onPreview,
  }) {
    return ValueListenableBuilder<int>(
      valueListenable: selected,
      builder: (context, current, _) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: GE.text,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 7),
            Row(
              children: List.generate(variants.length, (index) {
                final active = current == index;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: index == variants.length - 1 ? 0 : 7,
                    ),
                    child: Semantics(
                      button: true,
                      selected: active,
                      label: '$title: ${variants[index]}',
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          unawaited(onSelected(index));
                          unawaited(onPreview(index));
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          height: 34,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: active
                                ? GE.primary.withValues(alpha: 0.14)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: active ? GE.primary : GE.glassBorder,
                            ),
                          ),
                          child: Text(
                            variants[index],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: active ? GE.primary : GE.text,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
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
}
