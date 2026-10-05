import 'dart:math' as math;
import 'dart:typed_data';

/// Small original GhostChat sound effects rendered as mono PCM WAV.
///
/// Keeping the waveforms in source makes the bundled sound assets reproducible
/// and avoids shipping third-party notification samples.
class GhostSoundWaveforms {
  GhostSoundWaveforms._();

  static const int sampleRate = 22050;

  static const int tapVariantCount = 10;
  static const List<String> tapVariantNames = [
    'Поп',
    'Клик',
    'Стекло',
    'Дерево',
    'Плик',
    'Двойной',
    'Цифра',
    'Воздух',
    'Пружина',
    'Звон',
  ];
  static const List<_TapPreset> _tapPresets = [
    _TapPreset(index: 0, duration: 0.075, style: _TapStyle.bubble),
    _TapPreset(index: 1, duration: 0.038, style: _TapStyle.click),
    _TapPreset(index: 2, duration: 0.085, style: _TapStyle.glass),
    _TapPreset(index: 3, duration: 0.055, style: _TapStyle.wood),
    _TapPreset(index: 4, duration: 0.070, style: _TapStyle.pluck),
    _TapPreset(index: 5, duration: 0.060, style: _TapStyle.doubleClick),
    _TapPreset(index: 6, duration: 0.062, style: _TapStyle.digital),
    _TapPreset(index: 7, duration: 0.052, style: _TapStyle.air),
    _TapPreset(index: 8, duration: 0.095, style: _TapStyle.spring),
    _TapPreset(index: 9, duration: 0.105, style: _TapStyle.bell),
  ];

  /// Ten deliberately different, original UI tap sounds.
  static Uint8List tap() => tapVariant(0);

  static Uint8List tapVariant(int variant) {
    final preset = _tapPresets[variant.clamp(0, tapVariantCount - 1).toInt()];
    final count = (sampleRate * preset.duration).round();
    final samples = List<double>.filled(count, 0);
    var lowNoise = 0.0;
    var peak = 0.0;

    for (var i = 0; i < count; i++) {
      final time = i / sampleRate;
      final noise = _transientNoise(i + preset.index * 7919);
      lowNoise += 0.16 * (noise - lowNoise);
      final highNoise = noise - lowNoise;
      final value = switch (preset.style) {
        _TapStyle.bubble => _bubble(time, preset, highNoise),
        _TapStyle.click => _click(time, highNoise),
        _TapStyle.glass => _glass(time),
        _TapStyle.wood => _wood(time, noise, lowNoise),
        _TapStyle.pluck => _pluck(time, preset),
        _TapStyle.doubleClick => _doubleClick(time, highNoise),
        _TapStyle.digital => _digital(time, preset),
        _TapStyle.air => _air(time, noise, lowNoise),
        _TapStyle.spring => _spring(time, preset),
        _TapStyle.bell => _bell(time),
      };
      samples[i] = value;
      peak = math.max(peak, value.abs());
    }

    final bytes = _wavHeader(sampleRate, count * 2);
    final header = ByteData.sublistView(bytes);
    final gain = peak == 0 ? 1.0 : 0.72 / peak;
    for (var i = 0; i < count; i++) {
      final normalized = (samples[i] * gain).clamp(-0.92, 0.92);
      header.setInt16(44 + i * 2, (normalized * 32767).round(), Endian.little);
    }
    return bytes;
  }

  static double _bubble(double t, _TapPreset p, double highNoise) {
    final crack = highNoise * 0.95 * math.exp(-t * 680);
    final membrane = _sweep(t, 0.009, 1750, 520) * 0.30 * math.exp(-t * 300);
    final bloop = _sweep(t, p.duration, 390, 95) * 0.32 * math.exp(-t * 47);
    final bass = math.sin(2 * math.pi * 155 * t) * 0.25 * math.exp(-t * 39);
    return crack + membrane + bloop + bass;
  }

  static double _click(double t, double highNoise) {
    final snap = highNoise * 0.8 * math.exp(-t * 1250);
    final mechanism =
        math.sin(2 * math.pi * 2350 * t) * 0.45 * math.exp(-t * 420);
    final body = math.sin(2 * math.pi * 960 * t) * 0.18 * math.exp(-t * 230);
    return snap + mechanism + body;
  }

  static double _glass(double t) =>
      math.sin(2 * math.pi * 1760 * t) * 0.47 * math.exp(-t * 33) +
      math.sin(2 * math.pi * 2870 * t + 0.4) * 0.25 * math.exp(-t * 47) +
      math.sin(2 * math.pi * 4210 * t + 0.8) * 0.10 * math.exp(-t * 63);

  static double _wood(double t, double noise, double lowNoise) =>
      (lowNoise * 0.55 + (noise - lowNoise) * 0.22) * math.exp(-t * 850) +
      math.sin(2 * math.pi * 185 * t) * 0.56 * math.exp(-t * 80) +
      math.sin(2 * math.pi * 325 * t) * 0.20 * math.exp(-t * 120);

  static double _pluck(double t, _TapPreset p) =>
      _sweep(t, p.duration, 720, 275) * 0.58 * math.exp(-t * 37) +
      _sweep(t, p.duration, 1440, 550) * 0.14 * math.exp(-t * 62);

  static double _doubleClick(double t, double highNoise) {
    final second = t - 0.025;
    final firstClick = highNoise * 0.55 * math.exp(-t * 1450);
    final secondClick = second >= 0
        ? _transientNoise((second * sampleRate).round() + 41000) *
              0.48 *
              math.exp(-second * 1450)
        : 0.0;
    final tick = math.sin(2 * math.pi * 1800 * t) * 0.30 * math.exp(-t * 440);
    return firstClick + secondClick + tick;
  }

  static double _digital(double t, _TapPreset p) =>
      _sweep(t, p.duration, 470, 1320) * 0.48 * math.exp(-t * 32) +
      _sweep(t, p.duration, 940, 2640) * 0.14 * math.exp(-t * 48);

  static double _air(double t, double noise, double lowNoise) =>
      (noise * 0.18 + lowNoise * 0.82) * math.exp(-t * 78) +
      math.sin(2 * math.pi * 340 * t) * 0.20 * math.exp(-t * 65);

  static double _spring(double t, _TapPreset p) {
    final wobble = 0.72 + 0.28 * math.sin(2 * math.pi * 43 * t);
    return _sweep(t, p.duration, 880, 155) * 0.48 * math.exp(-t * 28) * wobble +
        _sweep(t, p.duration, 1760, 310) * 0.12 * math.exp(-t * 44);
  }

  static double _bell(double t) =>
      math.sin(2 * math.pi * 1180 * t) * 0.42 * math.exp(-t * 19) +
      math.sin(2 * math.pi * 1735 * t + 0.3) * 0.28 * math.exp(-t * 26) +
      math.sin(2 * math.pi * 2690 * t + 0.7) * 0.13 * math.exp(-t * 42);

  static double _transientNoise(int sampleIndex) {
    var value = (sampleIndex + 1) * 0x45d9f3b;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    return ((value & 0xffff) / 32767.5) - 1;
  }

  static double _sweep(double time, double duration, double from, double to) {
    final phase =
        2 *
        math.pi *
        (from * time + (to - from) * time * time / (2 * duration));
    return math.sin(phase);
  }

  static Uint8List notification() => _render(
    duration: 0.39,
    tones: const [
      _Tone(start: 0.000, duration: 0.150, fromHz: 660, toHz: 740, gain: 0.34),
      _Tone(start: 0.105, duration: 0.245, fromHz: 880, toHz: 988, gain: 0.31),
    ],
  );

  static const int effectVariantCount = 3;

  static Uint8List notificationVariant(int variant) => switch (variant
      .clamp(0, effectVariantCount - 1)
      .toInt()) {
    0 => notification(),
    1 => _render(
      duration: 0.43,
      tones: const [
        _Tone(start: 0.00, duration: 0.12, fromHz: 740, toHz: 784, gain: 0.27),
        _Tone(start: 0.13, duration: 0.14, fromHz: 988, toHz: 1047, gain: 0.30),
        _Tone(
          start: 0.29,
          duration: 0.14,
          fromHz: 1318,
          toHz: 1397,
          gain: 0.28,
        ),
      ],
    ),
    _ => _render(
      duration: 0.36,
      tones: const [
        _Tone(start: 0.00, duration: 0.16, fromHz: 523, toHz: 587, gain: 0.32),
        _Tone(start: 0.19, duration: 0.15, fromHz: 659, toHz: 698, gain: 0.30),
      ],
    ),
  };

  static Uint8List call() => callVariant(0);

  static Uint8List callVariant(int variant) => switch (variant
      .clamp(0, effectVariantCount - 1)
      .toInt()) {
    0 => _render(
      duration: 1.05,
      tones: const [
        _Tone(start: 0.00, duration: 0.20, fromHz: 660, toHz: 740, gain: 0.32),
        _Tone(start: 0.29, duration: 0.20, fromHz: 880, toHz: 988, gain: 0.32),
        _Tone(start: 0.60, duration: 0.20, fromHz: 660, toHz: 740, gain: 0.32),
      ],
    ),
    1 => _render(
      duration: 1.12,
      tones: const [
        _Tone(start: 0.00, duration: 0.13, fromHz: 880, toHz: 880, gain: 0.31),
        _Tone(start: 0.18, duration: 0.13, fromHz: 660, toHz: 660, gain: 0.30),
        _Tone(start: 0.46, duration: 0.13, fromHz: 880, toHz: 880, gain: 0.31),
        _Tone(start: 0.64, duration: 0.13, fromHz: 660, toHz: 660, gain: 0.30),
      ],
    ),
    _ => _render(
      duration: 0.96,
      tones: const [
        _Tone(start: 0.00, duration: 0.28, fromHz: 494, toHz: 523, gain: 0.35),
        _Tone(start: 0.37, duration: 0.28, fromHz: 587, toHz: 622, gain: 0.35),
      ],
    ),
  };

  static Uint8List success() => successVariant(0);

  static Uint8List successVariant(int variant) => switch (variant
      .clamp(0, effectVariantCount - 1)
      .toInt()) {
    0 => _render(
      duration: 0.23,
      tones: const [
        _Tone(
          start: 0.000,
          duration: 0.105,
          fromHz: 587,
          toHz: 659,
          gain: 0.24,
        ),
        _Tone(
          start: 0.085,
          duration: 0.145,
          fromHz: 784,
          toHz: 880,
          gain: 0.22,
        ),
      ],
    ),
    1 => _render(
      duration: 0.32,
      tones: const [
        _Tone(start: 0.00, duration: 0.075, fromHz: 523, toHz: 587, gain: 0.23),
        _Tone(start: 0.08, duration: 0.075, fromHz: 659, toHz: 740, gain: 0.23),
        _Tone(start: 0.16, duration: 0.14, fromHz: 880, toHz: 1047, gain: 0.25),
      ],
    ),
    _ => _render(
      duration: 0.28,
      tones: const [
        _Tone(start: 0.00, duration: 0.19, fromHz: 784, toHz: 784, gain: 0.19),
        _Tone(start: 0.02, duration: 0.17, fromHz: 988, toHz: 988, gain: 0.18),
        _Tone(
          start: 0.05,
          duration: 0.13,
          fromHz: 1318,
          toHz: 1318,
          gain: 0.17,
        ),
      ],
    ),
  };

  static Uint8List warning() => warningVariant(0);

  static Uint8List warningVariant(int variant) => switch (variant
      .clamp(0, effectVariantCount - 1)
      .toInt()) {
    0 => _render(
      duration: 0.27,
      tones: const [
        _Tone(
          start: 0.000,
          duration: 0.120,
          fromHz: 494,
          toHz: 466,
          gain: 0.22,
        ),
        _Tone(
          start: 0.125,
          duration: 0.145,
          fromHz: 392,
          toHz: 349,
          gain: 0.20,
        ),
      ],
    ),
    1 => _render(
      duration: 0.38,
      tones: const [
        _Tone(start: 0.00, duration: 0.10, fromHz: 440, toHz: 415, gain: 0.24),
        _Tone(start: 0.13, duration: 0.10, fromHz: 440, toHz: 415, gain: 0.24),
        _Tone(start: 0.26, duration: 0.10, fromHz: 440, toHz: 415, gain: 0.24),
      ],
    ),
    _ => _render(
      duration: 0.34,
      tones: const [
        _Tone(start: 0.00, duration: 0.14, fromHz: 622, toHz: 554, gain: 0.25),
        _Tone(start: 0.16, duration: 0.14, fromHz: 466, toHz: 415, gain: 0.22),
      ],
    ),
  };

  static Uint8List error() => errorVariant(0);

  static Uint8List errorVariant(int variant) => switch (variant
      .clamp(0, effectVariantCount - 1)
      .toInt()) {
    0 => _render(
      duration: 0.31,
      tones: const [
        _Tone(
          start: 0.000,
          duration: 0.135,
          fromHz: 440,
          toHz: 392,
          gain: 0.23,
        ),
        _Tone(
          start: 0.145,
          duration: 0.165,
          fromHz: 330,
          toHz: 294,
          gain: 0.20,
        ),
      ],
    ),
    1 => _render(
      duration: 0.33,
      tones: const [
        _Tone(start: 0.00, duration: 0.10, fromHz: 415, toHz: 392, gain: 0.25),
        _Tone(start: 0.11, duration: 0.10, fromHz: 311, toHz: 294, gain: 0.24),
        _Tone(start: 0.22, duration: 0.10, fromHz: 233, toHz: 220, gain: 0.22),
      ],
    ),
    _ => _render(
      duration: 0.29,
      tones: const [
        _Tone(start: 0.00, duration: 0.24, fromHz: 220, toHz: 196, gain: 0.32),
        _Tone(start: 0.03, duration: 0.18, fromHz: 277, toHz: 247, gain: 0.14),
      ],
    ),
  };

  static Uint8List _render({
    required double duration,
    required List<_Tone> tones,
  }) {
    final sampleCount = (sampleRate * duration).round();
    final pcmLength = sampleCount * 2;
    final bytes = _wavHeader(sampleRate, pcmLength);
    final header = ByteData.sublistView(bytes);

    for (var index = 0; index < sampleCount; index++) {
      final time = index / sampleRate;
      var sample = 0.0;
      for (final tone in tones) {
        final localTime = time - tone.start;
        if (localTime < 0 || localTime >= tone.duration) continue;

        final progress = localTime / tone.duration;
        final phase =
            2 *
            math.pi *
            (tone.fromHz * localTime +
                (tone.toHz - tone.fromHz) *
                    localTime *
                    localTime /
                    (2 * tone.duration));
        final attack = math.min(1.0, localTime / 0.006);
        final release = math.min(1.0, (tone.duration - localTime) / 0.040);
        final decay = math.exp(-3.2 * progress);
        final envelope = attack * release * decay;
        final fundamental = math.sin(phase);
        final overtone = math.sin(phase * 2.01) * 0.16;
        // A very small, smoothed frequency-dependent brightening gives these
        // short tones their own glassy timbre without a hard-edged square wave.
        sample += (fundamental + overtone) * tone.gain * envelope;
      }

      final normalized = sample.clamp(-0.92, 0.92);
      final pcm = (normalized * 32767).round();
      header.setInt16(44 + index * 2, pcm, Endian.little);
    }

    return bytes;
  }

  static Uint8List _wavHeader(int rate, int pcmLength) {
    final bytes = Uint8List(44 + pcmLength);
    final header = ByteData.sublistView(bytes);
    void writeAscii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        bytes[offset + i] = value.codeUnitAt(i);
      }
    }

    writeAscii(0, 'RIFF');
    header.setUint32(4, 36 + pcmLength, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, rate, Endian.little);
    header.setUint32(28, rate * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    writeAscii(36, 'data');
    header.setUint32(40, pcmLength, Endian.little);
    return bytes;
  }
}

enum _TapStyle {
  bubble,
  click,
  glass,
  wood,
  pluck,
  doubleClick,
  digital,
  air,
  spring,
  bell,
}

class _TapPreset {
  final int index;
  final double duration;
  final _TapStyle style;

  const _TapPreset({
    required this.index,
    required this.duration,
    required this.style,
  });
}

class _Tone {
  final double start;
  final double duration;
  final double fromHz;
  final double toHz;
  final double gain;

  const _Tone({
    required this.start,
    required this.duration,
    required this.fromHz,
    required this.toHz,
    required this.gain,
  });
}
