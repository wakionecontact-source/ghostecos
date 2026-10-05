import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/local/app_logger.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import 'profile_music_cache.dart';

part 'audio_notification_service.dart';
part 'global_audio_player_surface.dart';

enum AudioRepeatMode { off, one, all }

enum AudioPlayerPosition { top, bottom }

enum AudioPlayerVisualStyle { matte, compact }

/// One app-wide player. Network sources are handed directly to audioplayers;
/// the native backend buffers HTTP progressively and starts as soon as it has
/// enough data, so the app never reads a whole track into Dart memory.
class GlobalAudioPlayer extends ChangeNotifier {
  GlobalAudioPlayer._() {
    unawaited(_player.setReleaseMode(ReleaseMode.stop));
    unawaited(_loadPosition());
    _positionSub = _player.onPositionChanged.listen((value) {
      _position = value;
      notifyListeners();
      _syncNotification();
    });
    _durationSub = _player.onDurationChanged.listen((value) {
      if (value > Duration.zero) _duration = value;
      notifyListeners();
      _syncNotification();
    });
    _stateSub = _player.onPlayerStateChanged.listen((value) {
      _state = value;
      if (value == PlayerState.playing) _loading = false;
      notifyListeners();
      _syncNotification();
    });
    _completeSub = _player.onPlayerComplete.listen((_) {
      unawaited(_enqueue(_advanceAfterComplete));
    });
  }

  static final GlobalAudioPlayer instance = GlobalAudioPlayer._();

  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<void>? _completeSub;

  List<Map<String, dynamic>> _queue = const [];
  int _currentIndex = 0;
  int _loadGeneration = 0;
  Future<void> _playbackTail = Future<void>.value();
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  PlayerState _state = PlayerState.stopped;
  bool _loading = false;
  String? _error;
  double _volume = 1.0;
  double _nativeVolume = 1.0;
  bool _muted = false;
  int _volumeRevision = 0;
  bool _volumeFadeQueued = false;
  AudioRepeatMode repeatMode = AudioRepeatMode.off;
  bool shuffle = false;
  bool reverseOrder = false;
  AudioPlayerVisualStyle visualStyle = AudioPlayerVisualStyle.matte;
  final ValueNotifier<AudioPlayerPosition> positionNotifier = ValueNotifier(
    AudioPlayerPosition.bottom,
  );

  List<Map<String, dynamic>> get queue => List.unmodifiable(_queue);
  Map<String, dynamic>? get currentTrack =>
      _queue.isEmpty ? null : _queue[_currentIndex];
  int get currentIndex => _currentIndex;
  Duration get position => _position;
  Duration get duration => _effectiveDuration;
  Duration get buffered => _buffered;
  PlayerState get state => _state;
  bool get isPlaying => _state == PlayerState.playing;
  bool get isLoading => _loading;
  String? get error => _error;
  bool get isActive => _queue.isNotEmpty && currentTrack != null;
  double get volume => _volume;
  bool get isMuted => _muted;
  double get effectiveVolume => _muted ? 0 : _volume;
  double _playbackRate = 1.0;
  double get playbackRate => _playbackRate;

  Future<void> _loadPosition() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString('ghost_audio_player_position_v1');
    if (value == AudioPlayerPosition.top.name) {
      positionNotifier.value = AudioPlayerPosition.top;
      notifyListeners();
    }
    final savedVolume = prefs.getDouble('ghost_audio_player_volume_v1');
    if (savedVolume != null) _volume = savedVolume.clamp(0.0, 1.0).toDouble();
    _muted = prefs.getBool('ghost_audio_player_muted_v1') ?? false;
    final savedStyle = prefs.getString('ghost_audio_player_visual_style_v1');
    visualStyle = AudioPlayerVisualStyle.values.firstWhere(
      (value) => value.name == savedStyle,
      orElse: () => AudioPlayerVisualStyle.matte,
    );
    notifyListeners();
  }

  void setPosition(AudioPlayerPosition value) {
    if (positionNotifier.value == value) return;
    positionNotifier.value = value;
    notifyListeners();
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) =>
            prefs.setString('ghost_audio_player_position_v1', value.name),
      ),
    );
  }

  void setVisualStyle(AudioPlayerVisualStyle value) {
    if (visualStyle == value) return;
    visualStyle = value;
    notifyListeners();
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) =>
            prefs.setString('ghost_audio_player_visual_style_v1', value.name),
      ),
    );
  }

  void setVolume(double value) {
    _volume = value.clamp(0.0, 1.0).toDouble();
    if (_volume > 0.01) _muted = false;
    _volumeRevision++;
    notifyListeners();
    _queueVolumeFade();
    unawaited(
      SharedPreferences.getInstance().then((prefs) async {
        await prefs.setDouble('ghost_audio_player_volume_v1', _volume);
        await prefs.setBool('ghost_audio_player_muted_v1', _muted);
      }),
    );
  }

  void toggleMute() {
    _muted = !_muted;
    _volumeRevision++;
    notifyListeners();
    _queueVolumeFade();
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setBool('ghost_audio_player_muted_v1', _muted),
      ),
    );
  }

  Future<void> playQueue(
    List<Map<String, dynamic>> tracks, {
    int startIndex = 0,
  }) => _enqueue(() async {
    final previousTrack = currentTrack;
    final next = tracks
        .map((track) => Map<String, dynamic>.from(track))
        .take(3)
        .toList(growable: false);
    if (next.isEmpty) {
      await _stopNow(clearQueue: true);
      return;
    }
    _queue = next;
    _currentIndex = startIndex.clamp(0, next.length - 1).toInt();
    _duration = _trackDuration(currentTrack);
    await _loadCurrent();
    if (previousTrack != null &&
        globalAudioTrackKey(previousTrack) !=
            globalAudioTrackKey(currentTrack)) {
      await _cleanupLocalTrack(previousTrack);
    }
  });

  Future<void> playTrack(Map<String, dynamic> track) => _enqueue(() async {
    final previousTrack = currentTrack;
    final existing = _queue.indexWhere(
      (item) => _trackKey(item) == _trackKey(track),
    );
    if (existing < 0) {
      _queue = [Map<String, dynamic>.from(track)];
      _currentIndex = 0;
    } else {
      _currentIndex = existing;
    }
    _duration = _trackDuration(currentTrack);
    await _loadCurrent();
    if (previousTrack != null &&
        globalAudioTrackKey(previousTrack) !=
            globalAudioTrackKey(currentTrack)) {
      await _cleanupLocalTrack(previousTrack);
    }
  });

  Future<void> toggle() => _enqueue(() async {
    if (isPlaying) {
      await _fadeNativeVolume(0);
      await _player.pause();
      _nativeVolume = 0;
      return;
    }
    if (_queue.isEmpty) return;
    if (_state == PlayerState.completed || _state == PlayerState.stopped) {
      await _loadCurrent();
    } else {
      await _player.setVolume(0);
      _nativeVolume = 0;
      await _player.resume();
      await _fadeNativeVolume(effectiveVolume);
    }
  });

  Future<void> next() => _enqueue(() async {
    if (_queue.isEmpty) return;
    await _fadeNativeVolume(0);
    final index = _nextIndex(from: _currentIndex, manual: true);
    if (index == null) {
      await _stopNow(clearQueue: false);
      return;
    }
    _currentIndex = index;
    await _loadCurrent();
  });

  Future<void> previous() => _enqueue(() async {
    if (_queue.isEmpty) return;
    if (_position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    final index = _nextIndex(
      from: _currentIndex,
      manual: true,
      backwards: true,
    );
    if (index == null) return;
    await _fadeNativeVolume(0);
    _currentIndex = index;
    await _loadCurrent();
  });

  void previewSeek(Duration value) {
    final total = _effectiveDuration;
    final target = total <= Duration.zero
        ? value
        : Duration(
            milliseconds: value.inMilliseconds.clamp(0, total.inMilliseconds),
          );
    _position = target;
    notifyListeners();
  }

  Future<void> seek(Duration value) async {
    final generation = _loadGeneration;
    final total = _effectiveDuration;
    final target = total <= Duration.zero
        ? value
        : Duration(
            milliseconds: value.inMilliseconds.clamp(0, total.inMilliseconds),
          );
    _position = target;
    notifyListeners();
    if (generation != _loadGeneration) return;
    try {
      await _player.seek(target);
    } catch (error) {
      appLog.error('audio_player', 'seek failed: $error');
    }
  }

  Future<void> setPlaybackRate(double value) => _enqueue(() async {
    final next = value.clamp(0.5, 2.0).toDouble();
    _playbackRate = next;
    try {
      await _player.setPlaybackRate(next);
    } catch (error) {
      appLog.warn('audio_player', 'playback rate failed: $error');
    }
    notifyListeners();
    _syncNotification();
  });

  Future<void> stop({bool clearQueue = false}) {
    _loadGeneration++;
    return _enqueue(() => _stopNow(clearQueue: clearQueue));
  }

  Future<void> _stopNow({required bool clearQueue}) async {
    final previousTrack = clearQueue ? currentTrack : null;
    await _fadeNativeVolume(0);
    await _player.stop();
    _nativeVolume = 0;
    _loading = false;
    _position = Duration.zero;
    _buffered = Duration.zero;
    _state = PlayerState.stopped;
    if (clearQueue) _queue = const [];
    notifyListeners();
    _syncNotification();
    if (previousTrack != null) await _cleanupLocalTrack(previousTrack);
  }

  void cycleRepeat() {
    repeatMode = switch (repeatMode) {
      AudioRepeatMode.off => AudioRepeatMode.all,
      AudioRepeatMode.all => AudioRepeatMode.one,
      AudioRepeatMode.one => AudioRepeatMode.off,
    };
    notifyListeners();
  }

  void setShuffle(bool value) {
    shuffle = value;
    notifyListeners();
  }

  void setReverseOrder(bool value) {
    reverseOrder = value;
    notifyListeners();
  }

  Future<void> _loadCurrent() async {
    final track = currentTrack;
    if (track == null) return;
    final generation = ++_loadGeneration;
    _loading = true;
    _error = null;
    _position = Duration.zero;
    _duration = _trackDuration(track);
    _buffered = Duration.zero;
    notifyListeners();
    _syncNotification();
    final urls = _sourceCandidates(track);
    final mime = _mimeType(track);
    final providedLocalPath = (track['local_path'] as String?)?.trim();
    String? cachedPath;
    try {
      cachedPath = await ProfileMusicCache.instance.pathFor(track);
      final localPath = cachedPath ?? providedLocalPath;
      if ((localPath == null || localPath.isEmpty) && urls.isEmpty) {
        throw Exception('empty audio source');
      }
      // Do not let two native MediaPlayer source preparations overlap. That
      // race leaves the Android player in loading forever and blocks controls.
      if (_state == PlayerState.playing) await _fadeNativeVolume(0);
      await _player.stop();
      if (generation != _loadGeneration) return;
      Object? lastError;
      if (localPath != null && localPath.isNotEmpty) {
        await _player
            .play(DeviceFileSource(localPath), volume: 0.0)
            .timeout(const Duration(seconds: 20));
      } else {
        for (final url in urls) {
          try {
            await _player
                .play(UrlSource(url, mimeType: mime), volume: 0.0)
                .timeout(const Duration(seconds: 20));
            lastError = null;
            break;
          } catch (error) {
            lastError = error;
            await _player.stop();
          }
        }
        if (lastError != null) throw lastError;
      }
      _nativeVolume = 0;
      try {
        await _player.setPlaybackRate(_playbackRate);
      } catch (_) {}
      await _fadeNativeVolume(effectiveVolume);
      if (generation != _loadGeneration) await _player.stop();
      if (cachedPath == null &&
          providedLocalPath == null &&
          ProfileMusicCache.instance.handles(track)) {
        unawaited(_cacheProfileTrack(track, urls));
      }
    } catch (error) {
      if (generation != _loadGeneration) return;
      _error = 'Не удалось загрузить звук';
      _state = PlayerState.stopped;
      appLog.error(
        'audio_player',
        'source failed urls=${urls.join('|')} mime=$mime '
            'track=${globalAudioTrackKey(track)} error=$error',
      );
    } finally {
      if (generation == _loadGeneration) {
        _loading = false;
        notifyListeners();
        _syncNotification();
      }
    }
  }

  Future<void> _cacheProfileTrack(
    Map<String, dynamic> track,
    List<String> urls,
  ) async {
    String? path;
    try {
      path = await ProfileMusicCache.instance.download(track, urls);
    } catch (_) {
      return;
    }
    if (path == null || path.isEmpty) return;
    final key = _trackKey(track);
    var changed = false;
    for (final queued in _queue) {
      if (_trackKey(queued) == key && queued['local_path'] != path) {
        queued['local_path'] = path;
        queued.remove('cleanup_local_path');
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  Duration get _effectiveDuration =>
      _duration > Duration.zero ? _duration : _trackDuration(currentTrack);

  Duration _trackDuration(Map<String, dynamic>? track) {
    final raw = track?['duration_ms'];
    if (raw is num && raw > 0) {
      return Duration(milliseconds: raw.round());
    }
    final parsed = int.tryParse(raw?.toString() ?? '');
    return parsed != null && parsed > 0
        ? Duration(milliseconds: parsed)
        : Duration.zero;
  }

  void _queueVolumeFade() {
    if (_volumeFadeQueued) return;
    _volumeFadeQueued = true;
    unawaited(
      _enqueue(() async {
        try {
          while (true) {
            final revision = _volumeRevision;
            await _fadeNativeVolume(effectiveVolume);
            if (revision == _volumeRevision) return;
          }
        } finally {
          _volumeFadeQueued = false;
          if (_volumeRevision > 0 && _nativeVolume != effectiveVolume) {
            _queueVolumeFade();
          }
        }
      }),
    );
  }

  Future<void> _fadeNativeVolume(double target) async {
    final from = _nativeVolume;
    if ((from - target).abs() < 0.01) {
      _nativeVolume = target;
      await _player.setVolume(target);
      return;
    }
    const steps = 9;
    for (var step = 1; step <= steps; step++) {
      final value = from + (target - from) * (step / steps);
      await _player.setVolume(value.clamp(0.0, 1.0).toDouble());
      _nativeVolume = value;
      await Future<void>.delayed(const Duration(milliseconds: 22));
    }
    _nativeVolume = target;
  }

  /// Serialize all operations that touch the single native player instance.
  /// A failed operation must not poison the tail for the next button press.
  Future<void> _enqueue(Future<void> Function() action) {
    final next = _playbackTail.then<void>(
      (_) => action(),
      onError: (Object error, StackTrace stack) => action(),
    );
    _playbackTail = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  Future<void> _advanceAfterComplete() async {
    if (_queue.isEmpty) return;
    if (repeatMode == AudioRepeatMode.one) {
      await _loadCurrent();
      return;
    }
    final index = _nextIndex(from: _currentIndex);
    if (index == null) {
      _state = PlayerState.completed;
      notifyListeners();
      return;
    }
    _currentIndex = index;
    await _loadCurrent();
  }

  int? _nextIndex({
    required int from,
    bool manual = false,
    bool backwards = false,
  }) {
    if (_queue.length <= 1 && repeatMode == AudioRepeatMode.off) {
      return null;
    }
    if (shuffle && !backwards) {
      final available = List<int>.generate(_queue.length, (i) => i)
        ..remove(from);
      if (available.isNotEmpty) {
        return available[math.Random().nextInt(available.length)];
      }
    }
    final direction = (reverseOrder ? -1 : 1) * (backwards ? -1 : 1);
    final candidate = from + direction;
    if (candidate >= 0 && candidate < _queue.length) return candidate;
    if (repeatMode == AudioRepeatMode.all || manual) {
      return direction > 0 ? 0 : _queue.length - 1;
    }
    return null;
  }

  List<String> _sourceCandidates(Map<String, dynamic> track) {
    final result = <String>[];
    void add(String value) {
      final normalized = _absoluteAudioUrl(value);
      if (normalized.isNotEmpty && !result.contains(normalized)) {
        result.add(normalized);
      }
    }

    final source = _trackString(track, const [
      'source',
      'Source',
    ]).toLowerCase();
    final slug = _trackString(track, const [
      'slug',
      'Slug',
      'track_slug',
      'trackSlug',
    ]);
    final ghosouId = _trackString(track, const [
      'track_id',
      'id',
      'ID',
      '_catalog_id',
    ]);
    final ghosouKey = slug.isNotEmpty ? slug : ghosouId;
    if (source == 'ghosou' && ghosouKey.isNotEmpty) {
      add('${GE.baseUrl}/sound/stream/${Uri.encodeComponent(ghosouKey)}');
    }

    // Profile payloads have existed in several shapes. Keep the direct file
    // URL as a fallback even for catalog tracks so a server-side migration
    // cannot turn one profile row into a permanently unplayable item.
    for (final key in const [
      'url',
      'audio_url',
      'audioUrl',
      'stream_url',
      'streamUrl',
      'file_url',
      'fileUrl',
      'source_url',
      'sourceUrl',
      'path',
      'src',
    ]) {
      add(_trackString(track, [key]));
    }

    if (result.isEmpty && ghosouKey.isNotEmpty && source == 'ghosou') {
      add('${GE.baseUrl}/sound/stream/${Uri.encodeComponent(ghosouKey)}');
    }
    return result;
  }

  String _trackString(Map<String, dynamic> track, List<String> keys) {
    for (final key in keys) {
      final value = track[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  String _absoluteAudioUrl(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (raw.startsWith('//')) return 'https:$raw';
    final base = GE.baseUrl.endsWith('/')
        ? GE.baseUrl.substring(0, GE.baseUrl.length - 1)
        : GE.baseUrl;
    return raw.startsWith('/') ? '$base$raw' : '$base/$raw';
  }

  String? _mimeType(Map<String, dynamic> track) {
    final raw = _trackString(track, const ['mime', 'Mime', 'mime_type']);
    if (raw.isNotEmpty) return raw.toLowerCase();
    final source = _trackString(track, const [
      'local_path',
      'url',
      'audio_url',
      'audioUrl',
      'stream_url',
      'streamUrl',
      'file_url',
      'fileUrl',
      'path',
      'src',
      'slug',
    ]).toLowerCase();
    final clean = source.split('?').first.split('#').first;
    if (clean.endsWith('.ogg') || clean.endsWith('.oga')) return 'audio/ogg';
    if (clean.endsWith('.wav')) return 'audio/wav';
    if (clean.endsWith('.m4a') || clean.endsWith('.mp4')) return 'audio/mp4';
    if (clean.endsWith('.aac')) return 'audio/aac';
    if (clean.endsWith('.webm')) return 'audio/webm';
    if (_trackString(track, const ['source', 'Source']).toLowerCase() ==
        'ghosou') {
      return 'audio/ogg';
    }
    return 'audio/mpeg';
  }

  String _trackKey(Map<String, dynamic> track) => globalAudioTrackKey(track);

  Future<void> _cleanupLocalTrack(Map<String, dynamic> track) async {
    if (track['cleanup_local_path'] != true) return;
    final path = (track['local_path'] as String?)?.trim();
    if (path == null || path.isEmpty) return;
    try {
      await File(path).delete();
    } catch (_) {}
  }

  void _syncNotification() {
    AudioNotificationService.instance.updateFromPlayer(this);
  }

  void syncNotification() => _syncNotification();

  @override
  void dispose() {
    unawaited(_player.dispose());
    unawaited(_positionSub?.cancel());
    unawaited(_durationSub?.cancel());
    unawaited(_stateSub?.cancel());
    unawaited(_completeSub?.cancel());
    positionNotifier.dispose();
    super.dispose();
  }
}

String globalAudioTrackKey(Map<String, dynamic>? track) {
  if (track == null) return '';
  return '${track['source'] ?? 'local'}:${track['track_id'] ?? track['local_path'] ?? track['url'] ?? track['name']}';
}

class _LegacyGlobalAudioPlayerHost extends StatelessWidget {
  final Widget child;

  const _LegacyGlobalAudioPlayerHost({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        GlobalAudioPlayer.instance,
        GlobalAudioPlayer.instance.positionNotifier,
      ]),
      builder: (context, _) {
        final player = GlobalAudioPlayer.instance;
        final viewPadding = MediaQuery.viewPaddingOf(context);
        final atTop = player.positionNotifier.value == AudioPlayerPosition.top;
        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            if (player.isActive)
              Positioned(
                left: 12,
                right: 12,
                top: atTop ? viewPadding.top + 8 : null,
                bottom: atTop ? null : viewPadding.bottom + 78,
                child: SafeArea(
                  top: false,
                  bottom: false,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: _GlobalAudioBar(player: player),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _GlobalAudioBar extends StatelessWidget {
  final GlobalAudioPlayer player;

  const _GlobalAudioBar({required this.player});

  @override
  Widget build(BuildContext context) {
    final track = player.currentTrack!;
    final total = player.duration.inMilliseconds > 0
        ? player.duration.inMilliseconds.toDouble()
        : ((track['duration_ms'] as num?)?.toDouble() ?? 0);
    final progress = total <= 0
        ? 0.0
        : (player.position.inMilliseconds / total).clamp(0.0, 1.0);
    final failed =
        player.error != null && !player.isLoading && !player.isPlaying;
    final artist =
        (track['artist'] as String?)?.trim().toString() ??
        'Неизвестный исполнитель';
    return GlassCard(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(8, 6, 6, 5),
      fillOverride: GE.surface.withValues(alpha: 0.94),
      ignoreSurfaceToggle: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _cover(track['cover_url'] as String?),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  onTap: () => _showPlayerSettings(context),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (track['name'] as String?)?.trim().toString() ??
                            'Музыка',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: GE.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      Text(
                        failed
                            ? 'Не удалось воспроизвести · нажмите ▶'
                            : artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: GE.sub,
                          fontSize: 12,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _control(CupertinoIcons.backward_fill, player.previous, GE.sub),
              _control(
                player.isPlaying
                    ? CupertinoIcons.pause_fill
                    : CupertinoIcons.play_fill,
                player.toggle,
                GE.primary,
                size: 20,
              ),
              _control(CupertinoIcons.forward_fill, player.next, GE.sub),
              _control(
                CupertinoIcons.ellipsis,
                () => _showPlayerSettings(context),
                GE.sub,
              ),
            ],
          ),
          const SizedBox(height: 4),
          LayoutBuilder(
            builder: (context, constraints) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: total > 0
                  ? (details) => _seekFromX(
                      details.localPosition.dx,
                      constraints.maxWidth,
                      total,
                    )
                  : null,
              onHorizontalDragUpdate: total > 0
                  ? (details) => _seekFromX(
                      details.localPosition.dx,
                      constraints.maxWidth,
                      total,
                    )
                  : null,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  minHeight: 3,
                  value: total > 0 ? progress : (player.isLoading ? null : 0),
                  backgroundColor: GE.sub.withValues(alpha: 0.2),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    failed ? GE.red : GE.primary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _control(
    IconData icon,
    VoidCallback onPressed,
    Color color, {
    double size = 16,
  }) {
    return SizedBox(
      width: 30,
      height: 30,
      child: IconButton(
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
        icon: Icon(icon, color: color, size: size),
      ),
    );
  }

  void _seekFromX(double x, double width, double total) {
    if (width <= 0 || total <= 0) return;
    final fraction = (x / width).clamp(0.0, 1.0);
    player.seek(Duration(milliseconds: (total * fraction).round()));
  }

  Widget _cover(String? value) {
    final url = value == null || value.isEmpty
        ? null
        : value.startsWith('http')
        ? value
        : '${GE.baseUrl}$value';
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 38,
        height: 38,
        child: url == null
            ? ColoredBox(
                color: GE.primary.withValues(alpha: 0.16),
                child: Icon(
                  CupertinoIcons.music_note_2,
                  color: GE.primary,
                  size: 19,
                ),
              )
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: GE.primary.withValues(alpha: 0.16),
                  child: Icon(
                    CupertinoIcons.music_note_2,
                    color: GE.primary,
                    size: 19,
                  ),
                ),
              ),
      ),
    );
  }

  void _showPlayerSettings(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: GE.surface,
      builder: (sheetContext) => AnimatedBuilder(
        animation: player,
        builder: (context, _) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Повтор'),
                subtitle: Text(switch (player.repeatMode) {
                  AudioRepeatMode.off => 'Выключен',
                  AudioRepeatMode.one => 'Текущий трек',
                  AudioRepeatMode.all => 'Вся очередь',
                }),
                trailing: Icon(CupertinoIcons.repeat, color: GE.primary),
                onTap: player.cycleRepeat,
              ),
              SwitchListTile(
                title: const Text('Перемешать очередь'),
                value: player.shuffle,
                onChanged: player.setShuffle,
              ),
              SwitchListTile(
                title: const Text('Обратный порядок'),
                subtitle: const Text('Следующий трек выбирается с конца'),
                value: player.reverseOrder,
                onChanged: player.setReverseOrder,
              ),
              ListTile(
                leading: const Icon(CupertinoIcons.arrow_up),
                title: const Text('Положение плеера'),
                subtitle: Text(
                  player.positionNotifier.value == AudioPlayerPosition.top
                      ? 'Сверху экрана'
                      : 'Снизу экрана',
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _positionChoice(
                        player,
                        AudioPlayerPosition.top,
                        'Сверху',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _positionChoice(
                        player,
                        AudioPlayerPosition.bottom,
                        'Снизу',
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(CupertinoIcons.clear),
                title: const Text('Остановить'),
                onTap: () async {
                  await player.stop(clearQueue: true);
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _positionChoice(
    GlobalAudioPlayer player,
    AudioPlayerPosition value,
    String label,
  ) {
    final selected = player.positionNotifier.value == value;
    return OutlinedButton(
      onPressed: () => player.setPosition(value),
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? GE.primary : GE.sub,
        side: BorderSide(color: selected ? GE.primary : GE.glassBorder),
      ),
      child: Text(label),
    );
  }
}

typedef GlobalAudioPlayerSourceOpener =
    Future<void> Function(BuildContext context, GlobalAudioPlayer player);

/// The player is deliberately a first-class surface: transport, timeline,
/// volume and dismiss are always visible. Advanced queue choices are also
/// direct controls, so there is no fragile overflow menu over the overlay.
class GlobalAudioPlayerHost extends StatelessWidget {
  final Widget child;
  final GlobalAudioPlayerSourceOpener? onOpenSource;

  const GlobalAudioPlayerHost({
    super.key,
    required this.child,
    this.onOpenSource,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        GlobalAudioPlayer.instance,
        GlobalAudioPlayer.instance.positionNotifier,
      ]),
      builder: (context, _) {
        final player = GlobalAudioPlayer.instance;
        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            if (player.isActive)
              Positioned.fill(
                child: _ModernFloatingAudioPlayer(
                  player: player,
                  onOpenSource: onOpenSource,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _FloatingAudioPlayer extends StatefulWidget {
  final GlobalAudioPlayer player;
  final GlobalAudioPlayerSourceOpener? onOpenSource;

  const _FloatingAudioPlayer({required this.player, this.onOpenSource});

  @override
  State<_FloatingAudioPlayer> createState() => _FloatingAudioPlayerState();
}

class _FloatingAudioPlayerState extends State<_FloatingAudioPlayer> {
  double? _dragTop;
  double _dragStartTop = 0;
  bool _dragging = false;

  double _barHeight() =>
      widget.player.visualStyle == AudioPlayerVisualStyle.compact ? 108 : 124;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = MediaQuery.viewPaddingOf(context);
        final height = _barHeight();
        final width = math.min(constraints.maxWidth - 24, 560.0);
        final left = math.max(12.0, (constraints.maxWidth - width) / 2);
        final topInset = padding.top + 8;
        final bottomInset = padding.bottom + 78;
        final maxTop = math.max(
          topInset,
          constraints.maxHeight - bottomInset - height,
        );
        final anchoredTop =
            widget.player.positionNotifier.value == AudioPlayerPosition.top
            ? topInset
            : maxTop;
        final top = (_dragTop ?? anchoredTop)
            .clamp(topInset, maxTop)
            .toDouble();

        return Stack(
          children: [
            AnimatedPositioned(
              duration: _dragging
                  ? Duration.zero
                  : const Duration(milliseconds: 340),
              curve: Curves.easeOutCubic,
              left: left,
              top: top,
              width: width,
              height: height,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPressStart: (_) {
                  setState(() {
                    _dragging = true;
                    _dragStartTop = top;
                    _dragTop = top;
                  });
                },
                onLongPressMoveUpdate: (details) {
                  if (!_dragging) return;
                  setState(() {
                    _dragTop = (_dragStartTop + details.offsetFromOrigin.dy)
                        .clamp(topInset, maxTop)
                        .toDouble();
                  });
                },
                onLongPressEnd: (_) {
                  final currentTop = _dragTop ?? top;
                  final center = currentTop + height / 2;
                  final position = center < constraints.maxHeight / 2
                      ? AudioPlayerPosition.top
                      : AudioPlayerPosition.bottom;
                  widget.player.setPosition(position);
                  setState(() {
                    _dragging = false;
                    _dragTop = null;
                  });
                },
                child: SizedBox(
                  height: height,
                  child: _GlobalAudioBarV2(
                    player: widget.player,
                    onOpenSource: widget.onOpenSource,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _GlobalAudioBarV2 extends StatelessWidget {
  final GlobalAudioPlayer player;
  final GlobalAudioPlayerSourceOpener? onOpenSource;

  const _GlobalAudioBarV2({required this.player, this.onOpenSource});

  @override
  Widget build(BuildContext context) {
    final track = player.currentTrack!;
    final compact = player.visualStyle == AudioPlayerVisualStyle.compact;
    final total = player.duration.inMilliseconds.toDouble();
    final progress = total <= 0
        ? 0.0
        : (player.position.inMilliseconds / total).clamp(0.0, 1.0).toDouble();
    final failed =
        player.error != null && !player.isLoading && !player.isPlaying;
    final title = _text(track['name'], 'Музыка');
    final artist = _text(track['artist'], 'Неизвестный исполнитель');

    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      child: GlassCard(
        radius: compact ? 19 : 25,
        padding: EdgeInsets.fromLTRB(
          compact ? 8 : 10,
          compact ? 7 : 9,
          compact ? 7 : 9,
          compact ? 6 : 8,
        ),
        fillOverride: GE.surface.withValues(alpha: compact ? 0.78 : 0.58),
        blurOverride: compact ? 18 : 28,
        ignoreSurfaceToggle: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                onOpenSource == null
                    ? _cover(track['cover_url'] as String?, compact ? 38 : 46)
                    : InkWell(
                        onTap: () => onOpenSource!(context, player),
                        borderRadius: BorderRadius.circular(12),
                        child: _cover(
                          track['cover_url'] as String?,
                          compact ? 38 : 46,
                        ),
                      ),
                const SizedBox(width: 9),
                Expanded(
                  child: InkWell(
                    onTap: onOpenSource == null
                        ? null
                        : () => onOpenSource!(context, player),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: GE.text,
                              fontSize: compact ? 13 : 14,
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          Text(
                            failed ? 'Не удалось загрузить звук' : artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: failed ? GE.red : GE.sub,
                              fontSize: compact ? 11 : 12,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                _control(
                  CupertinoIcons.shuffle,
                  () => player.setShuffle(!player.shuffle),
                  player.shuffle ? GE.primary : GE.sub,
                  size: 15,
                  tooltip: 'Перемешать очередь',
                ),
                _control(
                  CupertinoIcons.repeat,
                  player.cycleRepeat,
                  player.repeatMode == AudioRepeatMode.off
                      ? GE.sub
                      : GE.primary,
                  size: 15,
                  tooltip: 'Повтор',
                ),
                _control(
                  CupertinoIcons.clear_circled,
                  () => player.stop(clearQueue: true),
                  GE.sub,
                  size: 18,
                  tooltip: 'Убрать звук',
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _control(
                  CupertinoIcons.backward_fill,
                  player.previous,
                  GE.sub,
                  tooltip: 'Предыдущий трек',
                ),
                _control(
                  player.isLoading
                      ? CupertinoIcons.hourglass
                      : player.isPlaying
                      ? CupertinoIcons.pause_fill
                      : CupertinoIcons.play_fill,
                  player.isLoading ? () {} : player.toggle,
                  GE.primary,
                  size: 20,
                  tooltip: player.isPlaying ? 'Пауза' : 'Воспроизвести',
                ),
                _control(
                  CupertinoIcons.forward_fill,
                  player.next,
                  GE.sub,
                  tooltip: 'Следующий трек',
                ),
                const SizedBox(width: 3),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: compact ? 3 : 4,
                          thumbShape: RoundSliderThumbShape(
                            enabledThumbRadius: compact ? 5 : 6,
                          ),
                          overlayShape: RoundSliderOverlayShape(
                            overlayRadius: compact ? 12 : 15,
                          ),
                          activeTrackColor: failed ? GE.red : GE.primary,
                          inactiveTrackColor: GE.sub.withValues(alpha: 0.25),
                          thumbColor: failed ? GE.red : GE.primary,
                        ),
                        child: Slider(
                          value: progress,
                          min: 0,
                          max: 1,
                          onChanged: total <= 0
                              ? null
                              : (value) => player.previewSeek(
                                  Duration(
                                    milliseconds: (total * value).round(),
                                  ),
                                ),
                          onChangeEnd: total <= 0
                              ? null
                              : (value) => player.seek(
                                  Duration(
                                    milliseconds: (total * value).round(),
                                  ),
                                ),
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatTime(player.position),
                            style: TextStyle(color: GE.sub, fontSize: 10),
                          ),
                          Text(
                            _formatTime(player.duration),
                            style: TextStyle(color: GE.sub, fontSize: 10),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 3),
                _control(
                  player.isMuted || player.volume <= 0.01
                      ? CupertinoIcons.volume_off
                      : player.volume < 0.5
                      ? CupertinoIcons.volume_down
                      : CupertinoIcons.volume_up,
                  player.toggleMute,
                  player.isMuted ? GE.sub : GE.primary,
                  size: 17,
                  tooltip: player.isMuted ? 'Включить звук' : 'Выключить звук',
                ),
                SizedBox(
                  width: compact ? 64 : 88,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 5,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 11,
                      ),
                      activeTrackColor: GE.primary2,
                      inactiveTrackColor: GE.sub.withValues(alpha: 0.25),
                      thumbColor: GE.primary2,
                    ),
                    child: Slider(
                      value: player.volume,
                      min: 0,
                      max: 1,
                      onChanged: player.setVolume,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _control(
    IconData icon,
    VoidCallback onPressed,
    Color color, {
    double size = 16,
    String? tooltip,
  }) {
    return SizedBox(
      width: 30,
      height: 30,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
        icon: Icon(icon, color: color, size: size),
      ),
    );
  }

  Widget _cover(String? value, double size) {
    final url = value == null || value.isEmpty
        ? null
        : value.startsWith('http')
        ? value
        : '${GE.baseUrl}$value';
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: SizedBox(
        width: size,
        height: size,
        child: url == null
            ? ColoredBox(
                color: GE.primary.withValues(alpha: 0.16),
                child: Icon(
                  CupertinoIcons.music_note_2,
                  color: GE.primary,
                  size: size * 0.48,
                ),
              )
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: GE.primary.withValues(alpha: 0.16),
                  child: Icon(
                    CupertinoIcons.music_note_2,
                    color: GE.primary,
                    size: size * 0.48,
                  ),
                ),
              ),
      ),
    );
  }

  String _text(Object? value, String fallback) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  String _formatTime(Duration value) {
    final totalSeconds = value.inSeconds.clamp(0, 99 * 60 * 60);
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final restMinutes = minutes % 60;
      return '$hours:${restMinutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
