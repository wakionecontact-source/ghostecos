part of 'global_audio_player.dart';

/// Bridges the single in-app player to Android's media notification. The
/// notification owns no second decoder: every button delegates back to the
/// same GlobalAudioPlayer instance used by the Flutter UI.
class GhostAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  Future<void> Function()? onPlayRequested;
  Future<void> Function()? onPauseRequested;
  Future<void> Function()? onStopRequested;
  Future<void> Function()? onNextRequested;
  Future<void> Function()? onPreviousRequested;
  Future<void> Function(Duration)? onSeekRequested;
  Future<void> Function(double)? onSpeedRequested;
  String? _lastMediaItemId;
  Duration? _lastMediaItemDuration;

  @override
  Future<void> play() async => await onPlayRequested?.call();

  @override
  Future<void> pause() async => await onPauseRequested?.call();

  @override
  Future<void> stop() async => await onStopRequested?.call();

  @override
  Future<void> skipToNext() async => await onNextRequested?.call();

  @override
  Future<void> skipToPrevious() async => await onPreviousRequested?.call();

  @override
  Future<void> seek(Duration position) async =>
      await onSeekRequested?.call(position);

  @override
  Future<void> setSpeed(double speed) async =>
      await onSpeedRequested?.call(speed);

  void updateFromPlayer(GlobalAudioPlayer player) {
    final track = player.currentTrack;
    if (track == null) {
      if (_lastMediaItemId != null) {
        mediaItem.add(null);
        queue.add(const <MediaItem>[]);
        _lastMediaItemId = null;
        _lastMediaItemDuration = null;
      }
      playbackState.add(_stateFor(player));
      return;
    }

    final item = MediaItem(
      id: globalAudioTrackKey(track),
      title: _text(track['name'], 'Музыка'),
      artist: _text(track['artist'], 'GhostChat'),
      album: _text(track['album'], 'GhostChat'),
      duration: player.duration > Duration.zero
          ? player.duration
          : _trackDurationForNotification(track),
      artUri: _artUri(track['cover_url']),
    );
    if (_lastMediaItemId != item.id ||
        _lastMediaItemDuration != item.duration) {
      mediaItem.add(item);
      queue.add(<MediaItem>[item]);
      _lastMediaItemId = item.id;
      _lastMediaItemDuration = item.duration;
    }
    playbackState.add(_stateFor(player));
  }

  PlaybackState _stateFor(GlobalAudioPlayer player) {
    final processingState = player.isLoading
        ? AudioProcessingState.loading
        : switch (player.state) {
            PlayerState.playing ||
            PlayerState.paused => AudioProcessingState.ready,
            PlayerState.completed => AudioProcessingState.completed,
            PlayerState.stopped ||
            PlayerState.disposed => AudioProcessingState.idle,
          };
    final playing = player.isPlaying;
    return PlaybackState(
      controls: <MediaControl>[
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const <MediaAction>{
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const <int>[0, 1, 2],
      processingState: processingState,
      playing: playing,
      updatePosition: player.position,
      bufferedPosition: player.buffered,
      speed: player.playbackRate,
    );
  }

  static String _text(Object? value, String fallback) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  static Uri? _artUri(Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return null;
    return Uri.tryParse(raw.startsWith('http') ? raw : '${GE.baseUrl}$raw');
  }

  static Duration _trackDurationForNotification(Map<String, dynamic> track) {
    final raw = track['duration_ms'];
    final ms = raw is num ? raw.round() : int.tryParse('$raw') ?? 0;
    return ms > 0 ? Duration(milliseconds: ms) : Duration.zero;
  }
}

class AudioNotificationService {
  AudioNotificationService._();

  static final instance = AudioNotificationService._();

  GhostAudioHandler? _handler;
  bool _initializing = false;

  GhostAudioHandler? get handler => _handler;

  Future<void> init() async {
    if (_handler != null || _initializing) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    _initializing = true;
    try {
      _handler = await AudioService.init(
        builder: () => GhostAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'online.ghost_chat.chat.audio',
          androidNotificationChannelName: 'GhostChat audio',
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: false,
          androidNotificationIcon: 'drawable/ic_notification',
        ),
      );
    } finally {
      _initializing = false;
    }
  }

  void bind(GlobalAudioPlayer player) {
    final target = _handler;
    if (target == null) return;
    target.onPlayRequested = player.toggle;
    target.onPauseRequested = player.toggle;
    target.onStopRequested = () => player.stop(clearQueue: true);
    target.onNextRequested = player.next;
    target.onPreviousRequested = player.previous;
    target.onSeekRequested = player.seek;
    target.onSpeedRequested = player.setPlaybackRate;
    player.syncNotification();
  }

  void updateFromPlayer(GlobalAudioPlayer player) {
    _handler?.updateFromPlayer(player);
  }
}
