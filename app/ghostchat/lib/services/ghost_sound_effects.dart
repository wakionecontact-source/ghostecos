import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'ghost_asset_ota.dart';
import 'sound_settings.dart';

/// Preloaded, original GhostChat UI tones. Route the short in-app effects to
/// the media stream so Android's silent ringer mode does not mute taps and
/// previews. No audio focus is requested, so these effects do not pause music.
class GhostSoundEffects {
  GhostSoundEffects._();

  static final GhostSoundEffects instance = GhostSoundEffects._();

  static final AudioContext _context = AudioContext(
    android: const AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.media,
      audioFocus: AndroidAudioFocus.none,
    ),
    iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
  );

  final List<AudioPool> _tapPools = [];
  final Map<int, Future<AudioPool>> _notificationPools = {};
  final Map<int, Future<AudioPool>> _callPools = {};
  final Map<int, Future<AudioPool>> _successPools = {};
  final Map<int, Future<AudioPool>> _warningPools = {};
  final Map<int, Future<AudioPool>> _errorPools = {};
  final Set<StopFunction> _activeCallStops = <StopFunction>{};
  Future<void>? _initializing;
  int _callPlaybackGeneration = 0;
  int? _loadedAssetRevision;
  bool _assetRevisionListenerAttached = false;
  Future<void>? _assetRevisionReload;

  Future<void> initialize() {
    if (!_assetRevisionListenerAttached) {
      GhostAssetOta.instance.revisionNotifier.addListener(
        _onAssetRevisionChanged,
      );
      _assetRevisionListenerAttached = true;
    }
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    final startingRevision = GhostAssetOta.instance.revisionNotifier.value;
    try {
      await SoundSettings.instance.load();
      for (
        var variant = 0;
        variant < SoundSettings.tapVariantCount;
        variant++
      ) {
        final tapAsset = variant == 0
            ? 'sounds/ghost_tap.wav'
            : 'sounds/ghost_tap_${variant + 1}.wav';
        _tapPools.add(await _createPool(tapAsset));
      }
      _loadedAssetRevision = startingRevision;
      if (GhostAssetOta.instance.revisionNotifier.value != startingRevision) {
        _onAssetRevisionChanged();
      }
    } catch (error) {
      _initializing = null;
      if (kDebugMode) debugPrint('[sound] preload failed: $error');
    }
  }

  Future<AudioPool> _createPool(String assetPath) async {
    final data = await GhostAssetOta.instance.loadAssetData(
      'assets/$assetPath',
    );
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    return AudioPool.create(
      source: BytesSource(bytes, mimeType: 'audio/wav'),
      audioContext: _context,
      minPlayers: 1,
      maxPlayers: 3,
    );
  }

  void _onAssetRevisionChanged() {
    final installedRevision = GhostAssetOta.instance.revisionNotifier.value;
    if (_loadedAssetRevision == null ||
        _loadedAssetRevision == installedRevision ||
        _assetRevisionReload != null) {
      return;
    }
    final reload = _reloadPoolsForAssetRevision();
    _assetRevisionReload = reload;
    unawaited(
      reload.whenComplete(() {
        if (identical(_assetRevisionReload, reload)) {
          _assetRevisionReload = null;
        }
        _onAssetRevisionChanged();
      }),
    );
  }

  Future<void> _reloadPoolsForAssetRevision() async {
    final pools = <AudioPool>{..._tapPools};
    for (final pending in <Future<AudioPool>>[
      ..._notificationPools.values,
      ..._callPools.values,
      ..._successPools.values,
      ..._warningPools.values,
      ..._errorPools.values,
    ]) {
      try {
        pools.add(await pending);
      } catch (_) {
        // A failed pool is discarded with the rest; it will be retried on use.
      }
    }
    await stopCall();
    _tapPools.clear();
    _notificationPools.clear();
    _callPools.clear();
    _successPools.clear();
    _warningPools.clear();
    _errorPools.clear();
    for (final pool in pools) {
      try {
        await pool.dispose();
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[sound] old OTA pool disposal failed: $error');
        }
      }
    }
    _loadedAssetRevision = null;
    _initializing = null;
    await initialize();
  }

  AudioPool? _tapPoolAt(int variant) {
    if (_tapPools.isEmpty) return null;
    return _tapPools[variant.clamp(0, _tapPools.length - 1).toInt()];
  }

  Future<AudioPool?> _effectPool(
    Map<int, Future<AudioPool>> pools,
    String kind,
    int variant,
  ) async {
    final index = variant
        .clamp(0, SoundSettings.effectVariantCount - 1)
        .toInt();
    final suffix = index == 0 ? '' : '_${index + 1}';
    final pending = pools.putIfAbsent(
      index,
      () => _createPool('sounds/ghost_$kind$suffix.wav'),
    );
    try {
      return await pending;
    } catch (_) {
      if (identical(pools[index], pending)) pools.remove(index);
      rethrow;
    }
  }

  Future<void> playTap() => _play(
    () async => _tapPoolAt(SoundSettings.instance.uiTapVariantNotifier.value),
    enabled: () => SoundSettings.instance.uiSoundsEnabledNotifier.value,
  );

  Future<void> playSuccess() => _play(
    () => _effectPool(
      _successPools,
      'success',
      SoundSettings.instance.successVariantNotifier.value,
    ),
    enabled: () => SoundSettings.instance.uiSoundsEnabledNotifier.value,
  );

  Future<void> playWarning() => _play(
    () => _effectPool(
      _warningPools,
      'warning',
      SoundSettings.instance.warningVariantNotifier.value,
    ),
    enabled: () =>
        SoundSettings.instance.notificationSoundsEnabledNotifier.value,
  );

  Future<void> playError() => _play(
    () => _effectPool(
      _errorPools,
      'error',
      SoundSettings.instance.errorVariantNotifier.value,
    ),
    enabled: () =>
        SoundSettings.instance.notificationSoundsEnabledNotifier.value,
  );

  Future<void> previewTap() =>
      previewTapVariant(SoundSettings.instance.uiTapVariantNotifier.value);

  Future<void> previewTapVariant(int variant) =>
      _play(() async => _tapPoolAt(variant));

  Future<void> playNotification() => _play(
    () => _effectPool(
      _notificationPools,
      'notification',
      SoundSettings.instance.notificationVariantNotifier.value,
    ),
    enabled: () =>
        SoundSettings.instance.notificationSoundsEnabledNotifier.value,
  );

  /// Starts one call-ring instance and keeps its stop handle so an active
  /// sound can be interrupted immediately when the call ends or fails.
  Future<void> playCall() async {
    final generation = _callPlaybackGeneration;
    try {
      await initialize();
      if (generation != _callPlaybackGeneration ||
          !SoundSettings.instance.notificationSoundsEnabledNotifier.value) {
        return;
      }
      final pool = await _effectPool(
        _callPools,
        'call',
        SoundSettings.instance.callVariantNotifier.value,
      );
      if (pool == null ||
          generation != _callPlaybackGeneration ||
          !SoundSettings.instance.notificationSoundsEnabledNotifier.value) {
        return;
      }
      final stop = await pool.start(volume: 0.65);
      if (generation != _callPlaybackGeneration ||
          !SoundSettings.instance.notificationSoundsEnabledNotifier.value) {
        await stop();
        return;
      }
      _activeCallStops.add(stop);
    } catch (error) {
      if (kDebugMode) debugPrint('[sound] call playback failed: $error');
    }
  }

  /// Stops every currently playing call-ring instance without waiting for
  /// its normal audio duration to finish.
  Future<void> stopCall() async {
    _callPlaybackGeneration++;
    final stops = List<StopFunction>.of(_activeCallStops);
    _activeCallStops.clear();
    await Future.wait(
      stops.map((stop) async {
        try {
          await stop();
        } catch (error) {
          if (kDebugMode) debugPrint('[sound] call stop failed: $error');
        }
      }),
    );
  }

  Future<void> previewNotification() => previewNotificationVariant(
    SoundSettings.instance.notificationVariantNotifier.value,
  );

  Future<void> previewNotificationVariant(int variant) => _play(
    () => _effectPool(_notificationPools, 'notification', variant),
    volume: 0.8,
  );

  Future<void> previewCallVariant(int variant) =>
      _play(() => _effectPool(_callPools, 'call', variant), volume: 0.8);

  Future<void> previewSuccessVariant(int variant) =>
      _play(() => _effectPool(_successPools, 'success', variant));

  Future<void> previewWarningVariant(int variant) =>
      _play(() => _effectPool(_warningPools, 'warning', variant));

  Future<void> previewErrorVariant(int variant) =>
      _play(() => _effectPool(_errorPools, 'error', variant));

  Future<void> _play(
    Future<AudioPool?> Function() resolvePool, {
    double volume = 0.65,
    bool Function()? enabled,
  }) async {
    try {
      // Do not drop the first interaction while the app is still preloading
      // its custom tones. The old path kicked off initialize() and returned,
      // which made an early tap/preview completely silent.
      await initialize();
      if (enabled != null && !enabled()) return;
      final pool = await resolvePool();
      if (pool == null) return;
      await pool.start(volume: volume);
    } catch (error) {
      if (kDebugMode) debugPrint('[sound] playback failed: $error');
    }
  }
}
