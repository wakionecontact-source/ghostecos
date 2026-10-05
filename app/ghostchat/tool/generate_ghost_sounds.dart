import 'dart:io';

import 'package:ghost/services/ghost_sound_waveforms.dart';

Future<void> main() async {
  final outputs = <String, List<int>>{
    for (
      var variant = 0;
      variant < GhostSoundWaveforms.tapVariantCount;
      variant++
    )
      'assets/sounds/${variant == 0 ? 'ghost_tap.wav' : 'ghost_tap_${variant + 1}.wav'}':
          GhostSoundWaveforms.tapVariant(variant),
    for (
      var variant = 0;
      variant < GhostSoundWaveforms.effectVariantCount;
      variant++
    ) ...{
      'assets/sounds/${_assetName('notification', variant)}':
          GhostSoundWaveforms.notificationVariant(variant),
      'assets/sounds/${_assetName('call', variant)}':
          GhostSoundWaveforms.callVariant(variant),
      'assets/sounds/${_assetName('success', variant)}':
          GhostSoundWaveforms.successVariant(variant),
      'assets/sounds/${_assetName('warning', variant)}':
          GhostSoundWaveforms.warningVariant(variant),
      'assets/sounds/${_assetName('error', variant)}':
          GhostSoundWaveforms.errorVariant(variant),
      'android/app/src/main/res/raw/${_androidNotificationName(variant)}.wav':
          GhostSoundWaveforms.notificationVariant(variant),
    },
  };

  for (final entry in outputs.entries) {
    final file = File(entry.key);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(entry.value, flush: true);
    stdout.writeln('${file.path}: ${entry.value.length} bytes');
  }
}

String _assetName(String kind, int variant) {
  final suffix = variant == 0 ? '' : '_${variant + 1}';
  return 'ghost_$kind$suffix.wav';
}

String _androidNotificationName(int variant) {
  final suffix = variant == 0 ? '' : '_${variant + 1}';
  return 'ghostchat_notification$suffix';
}
