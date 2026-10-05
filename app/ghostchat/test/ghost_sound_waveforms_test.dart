import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/ghost_sound_waveforms.dart';

void main() {
  test('GhostChat tones are valid, non-empty mono PCM WAV files', () {
    final tapSounds = [
      for (
        var variant = 0;
        variant < GhostSoundWaveforms.tapVariantCount;
        variant++
      )
        GhostSoundWaveforms.tapVariant(variant),
    ];
    final effectSounds = [
      for (
        var variant = 0;
        variant < GhostSoundWaveforms.effectVariantCount;
        variant++
      ) ...[
        GhostSoundWaveforms.notificationVariant(variant),
        GhostSoundWaveforms.callVariant(variant),
        GhostSoundWaveforms.successVariant(variant),
        GhostSoundWaveforms.warningVariant(variant),
        GhostSoundWaveforms.errorVariant(variant),
      ],
    ];
    final sounds = [...tapSounds, ...effectSounds];

    for (final wav in sounds) {
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      final header = ByteData.sublistView(wav);
      expect(header.getUint16(20, Endian.little), 1); // PCM
      expect(header.getUint16(22, Endian.little), 1); // mono
      expect(header.getUint32(24, Endian.little), 22050);
      expect(header.getUint32(4, Endian.little), wav.length - 8);
      expect(wav.skip(44).any((sample) => sample != 0), isTrue);
    }

    expect(
      GhostSoundWaveforms.notification().length,
      greaterThan(GhostSoundWaveforms.tap().length),
    );
    expect(tapSounds, hasLength(10));
    expect(tapSounds.map(base64Encode).toSet(), hasLength(10));
    expect(tapSounds.every((wav) => wav.length < 6000), isTrue);
    expect(effectSounds, hasLength(15));
    expect(effectSounds.map(base64Encode).toSet(), hasLength(15));
  });
}
