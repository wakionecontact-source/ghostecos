import 'dart:async';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/local/app_logger.dart';
import '../services/api_client.dart';
import '../services/global_audio_player.dart';
import '../theme.dart';
import '../widgets/error_panel.dart';
import '../widgets/glass.dart';
import '../widgets/profile_banner.dart';

const _recentTracksKey = 'ghostsound_recent_profile_tracks_v1';

/// Maps the transport progress to the visible upload progress.
///
/// Dio reports that the request body is sent before the social backend has
/// finished probing/transcoding the audio. Keep the visible value below 100%
/// until the request itself returns successfully.
double profileMusicUploadProgress(int sent, int total) {
  if (total <= 0 || sent <= 0) return 0;
  final wire = (sent / total).clamp(0.0, 1.0).toDouble();
  return wire >= 0.999 ? 0.94 : wire * 0.94;
}

class ProfileMusicLibraryScreen extends StatefulWidget {
  final List<Map<String, dynamic>> tracks;
  final bool isOwner;
  final ProfileBannerConfig? banner;
  final String? sourceProfileUsername;

  const ProfileMusicLibraryScreen({
    super.key,
    required this.tracks,
    required this.isOwner,
    this.banner,
    this.sourceProfileUsername,
  });

  @override
  State<ProfileMusicLibraryScreen> createState() =>
      _ProfileMusicLibraryScreenState();
}

class _ProfileMusicLibraryScreenState extends State<ProfileMusicLibraryScreen> {
  final _api = ApiClient();
  late List<Map<String, dynamic>> _tracks = widget.tracks
      .map((track) => Map<String, dynamic>.from(track))
      .take(3)
      .toList();
  bool _saving = false;
  String? _error;
  String? _errorDetails;
  int? _errorLogId;
  List<Map<String, dynamic>>? _pendingSave;

  @override
  void initState() {
    super.initState();
    if (_tracks.isEmpty && widget.isOwner) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openCatalog();
      });
    }
  }

  Future<void> _openCatalog() async {
    if (_tracks.length >= 3 || !widget.isOwner) return;
    final added = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => GhostSoundCatalogScreen(remaining: 3 - _tracks.length),
      ),
    );
    if (added == null || !mounted) return;
    if (_tracks.any((track) => _trackKey(track) == _trackKey(added))) return;
    // Newly selected music is the current profile highlight, so keep it first
    // in both the UI and the ordered server playlist.
    await _saveTracks([added, ..._tracks]);
  }

  Future<void> _removeAt(int index) async {
    final next = [..._tracks]..removeAt(index);
    await _saveTracks(next);
  }

  Future<void> _move(int index, int delta) async {
    final target = index + delta;
    if (target < 0 || target >= _tracks.length) return;
    final next = [..._tracks];
    final item = next.removeAt(index);
    next.insert(target, item);
    await _saveTracks(next);
  }

  Future<void> _saveTracks(List<Map<String, dynamic>> next) async {
    if (!widget.isOwner || _saving) return;
    final requested = next.take(3).toList();
    _pendingSave = requested;
    setState(() => _saving = true);
    try {
      final response = await _api.updateOwnProfile(profileMusic: requested);
      final saved = _musicList(response['profile_music']);
      if (!mounted) return;
      setState(() {
        _tracks = saved;
        _error = null;
        _errorDetails = null;
        _errorLogId = null;
        _pendingSave = null;
      });
      if (saved.isEmpty) {
        GlobalAudioPlayer.instance.stop(clearQueue: true);
      } else {
        await GlobalAudioPlayer.instance.playQueue(_withSource(saved));
      }
      if (!mounted) return;
      Navigator.pop(context, saved);
    } catch (error) {
      final entry = appLog.error('profile_music', 'save failed: $error');
      if (mounted) {
        setState(() {
          _error = errorSummary(
            error,
            fallback: 'Не удалось сохранить музыку в профиле',
          );
          _errorDetails = errorDetails(error);
          _errorLogId = entry.id;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Музыка профиля'),
        backgroundColor: Colors.transparent,
        actions: [
          if (widget.isOwner && _tracks.length < 3)
            IconButton(
              tooltip: 'Добавить музыку',
              onPressed: _saving ? null : _openCatalog,
              icon: const Icon(CupertinoIcons.plus),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
        children: [
          if (_tracks.isEmpty)
            GlassCard(
              lite: true,
              padding: const EdgeInsets.all(24),
              onTap: widget.isOwner ? _openCatalog : null,
              child: Column(
                children: [
                  Icon(
                    CupertinoIcons.music_note_2,
                    color: GE.primary,
                    size: 34,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    widget.isOwner
                        ? 'Добавить музыку из GhostSound'
                        : 'В профиле пока нет музыки',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: GE.text, fontSize: 16),
                  ),
                ],
              ),
            )
          else
            for (var i = 0; i < _tracks.length; i++) _trackTile(i),
          if (_error != null) ...[
            const SizedBox(height: 12),
            AppErrorPanel(
              title: 'Музыка профиля',
              message: _error!,
              details: _errorDetails,
              logId: _errorLogId,
              compact: true,
              onRetry: _pendingSave == null || _saving
                  ? null
                  : () => _saveTracks(_pendingSave!),
            ),
          ],
          if (widget.isOwner && _tracks.isNotEmpty && _tracks.length < 3) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _saving ? null : _openCatalog,
              icon: const Icon(CupertinoIcons.plus),
              label: Text('Добавить ещё (${_tracks.length}/3)'),
            ),
          ],
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ],
      ),
    );
  }

  Widget _trackTile(int index) {
    final track = _tracks[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        lite: true,
        padding: const EdgeInsets.all(10),
        onTap: () =>
            GlobalAudioPlayer.instance.playTrack(_withSource([track]).first),
        child: Row(
          children: [
            _cover(track['cover_url'] as String?),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _text(track['name'], 'Музыка профиля'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: GE.text,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _text(track['artist'], 'Неизвестный исполнитель'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: GE.sub,
                      fontSize: 13,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
            if (widget.isOwner) ...[
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: _saving || index == 0
                    ? null
                    : () => _move(index, -1),
                icon: const Icon(CupertinoIcons.chevron_up, size: 17),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: _saving || index == _tracks.length - 1
                    ? null
                    : () => _move(index, 1),
                icon: const Icon(CupertinoIcons.chevron_down, size: 17),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: _saving ? null : () => _removeAt(index),
                icon: const Icon(CupertinoIcons.trash, size: 17),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _cover(String? value) {
    final url = value == null || value.isEmpty ? null : _absolute(value);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 58,
        height: 58,
        child: url == null
            ? ColoredBox(
                color: GE.primary.withValues(alpha: 0.16),
                child: Icon(CupertinoIcons.music_note_2, color: GE.primary),
              )
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: GE.primary.withValues(alpha: 0.16),
                  child: Icon(CupertinoIcons.music_note_2, color: GE.primary),
                ),
              ),
      ),
    );
  }

  String _absolute(String value) =>
      value.startsWith('http') ? value : '${GE.baseUrl}$value';

  String _trackKey(Map<String, dynamic>? track) => track == null
      ? ''
      : '${track['source'] ?? 'local'}:${track['track_id'] ?? track['url'] ?? track['name']}';

  List<Map<String, dynamic>> _withSource(List<Map<String, dynamic>> source) =>
      source
          .map(
            (track) => {
              ...track,
              '_audio_source': 'profile_music',
              if (widget.sourceProfileUsername != null)
                '_audio_profile_username': widget.sourceProfileUsername,
            },
          )
          .toList();

  List<Map<String, dynamic>> _musicList(Object? raw) {
    if (raw is Map) return [Map<String, dynamic>.from(raw)];
    if (raw is! List) return [];
    return raw.whereType<Map>().map(Map<String, dynamic>.from).take(3).toList();
  }

  String _text(Object? value, String fallback) {
    final valueText = value?.toString().trim() ?? '';
    return valueText.isEmpty ? fallback : valueText;
  }
}

class GhostSoundCatalogScreen extends StatefulWidget {
  final int remaining;

  const GhostSoundCatalogScreen({super.key, this.remaining = 3});

  @override
  State<GhostSoundCatalogScreen> createState() =>
      _GhostSoundCatalogScreenState();
}

class _GhostSoundCatalogScreenState extends State<GhostSoundCatalogScreen> {
  final _api = ApiClient();
  final _search = TextEditingController();
  List<Map<String, dynamic>> _tracks = [];
  List<String> _recentIds = [];
  String? _account;
  String? _error;
  bool _loading = true;
  bool _uploading = false;
  double _uploadProgress = 0;
  Timer? _uploadProgressTimer;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _api.ghosouGet('/sound/api/auth/me'),
        _api.ghosouGet('/sound/api/tracks', {'limit': 5000, 'sort': 'plays'}),
        SharedPreferences.getInstance(),
      ]);
      final account = results[0];
      final rawTracks = results[1];
      final prefs = results[2] as SharedPreferences;
      final recent = prefs.getStringList(_recentTracksKey) ?? const [];
      if (!mounted) return;
      setState(() {
        _account = account is Map
            ? (account['username'] ?? account['display_name'] ?? account['id'])
                  ?.toString()
            : null;
        _tracks = rawTracks is List
            ? rawTracks.whereType<Map>().map(_catalogTrack).toList()
            : [];
        _recentIds = recent;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = errorSummary(
          error,
          fallback: 'Не удалось загрузить каталог GhostSound',
        );
      });
    }
  }

  Map<String, dynamic> _catalogTrack(Map raw) {
    final track = Map<String, dynamic>.from(raw);
    final id = (track['ID'] ?? track['id'] ?? '').toString();
    final cover = (track['Cover'] ?? '').toString();
    final duration = track['Duration'];
    return {
      'source': 'ghosou',
      'track_id': id,
      'slug': (track['Slug'] ?? '').toString(),
      'name': (track['Title'] ?? track['title'] ?? 'Без названия').toString(),
      'artist':
          (track['Artist'] ?? track['artist'] ?? 'Неизвестный исполнитель')
              .toString(),
      'album': (track['Album'] ?? track['album'] ?? 'GhostSound').toString(),
      'mime': (track['Mime'] ?? track['mime'] ?? 'audio/ogg').toString(),
      'cover_url': cover.isEmpty ? null : cover,
      'duration_ms': duration is num ? (duration * 1000).round() : null,
      '_catalog_id': id,
    };
  }

  Future<void> _remember(Map<String, dynamic> track) async {
    final id = (track['track_id'] ?? '').toString();
    if (id.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final next = [
      id,
      ..._recentIds.where((value) => value != id),
    ].take(20).toList();
    await prefs.setStringList(_recentTracksKey, next);
    if (mounted) setState(() => _recentIds = next);
  }

  Future<void> _upload() async {
    if (_uploading || widget.remaining <= 0) return;
    final picked = await fs.openFile(
      acceptedTypeGroups: [
        fs.XTypeGroup(label: 'Аудио', extensions: ['mp3', 'm4a', 'wav', 'ogg']),
      ],
    );
    if (picked == null) return;
    setState(() {
      _uploading = true;
      _uploadProgress = 0.02;
    });
    try {
      final bytes = await picked.readAsBytes();
      if (bytes.length > 15 * 1024 * 1024) {
        throw Exception('максимальный размер — 15 МБ');
      }
      final uploaded = await _api.uploadProfileMusic(
        bytes: bytes,
        filename: picked.name,
        mime: _mime(picked.name),
        onSendProgress: (sent, total) {
          if (!mounted || total <= 0) return;
          final progress = profileMusicUploadProgress(sent, total);
          setState(() {
            if (progress > _uploadProgress) _uploadProgress = progress;
          });
          if (progress >= 0.94) _startUploadProcessingProgress();
        },
      );
      if (!mounted) return;
      _uploadProgressTimer?.cancel();
      setState(() => _uploadProgress = 1);
      await Future<void>.delayed(const Duration(milliseconds: 180));
      if (!mounted) return;
      Navigator.pop(context, uploaded);
    } catch (error) {
      if (mounted) {
        appLog.error('profile_music', 'upload failed: $error');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              errorSummary(error, fallback: 'Не удалось добавить файл'),
            ),
          ),
        );
      }
    } finally {
      _uploadProgressTimer?.cancel();
      _uploadProgressTimer = null;
      if (mounted) {
        setState(() {
          _uploading = false;
          _uploadProgress = 0;
        });
      }
    }
  }

  void _startUploadProcessingProgress() {
    if (_uploadProgressTimer != null) return;
    _uploadProgressTimer = Timer.periodic(const Duration(milliseconds: 550), (
      timer,
    ) {
      if (!mounted || !_uploading) {
        timer.cancel();
        _uploadProgressTimer = null;
        return;
      }
      setState(() {
        if (_uploadProgress < 0.98) {
          _uploadProgress = (_uploadProgress + 0.01)
              .clamp(0.94, 0.98)
              .toDouble();
        }
      });
    });
  }

  List<Map<String, dynamic>> get _visible {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return _tracks;
    return _tracks.where((track) {
      final haystack = [
        track['name'],
        track['artist'],
        track['album'],
      ].map((value) => value?.toString().toLowerCase() ?? '').join(' ');
      return haystack.contains(query);
    }).toList();
  }

  List<Map<String, dynamic>> get _recent => _recentIds
      .map(
        (id) => _tracks.cast<Map<String, dynamic>?>().firstWhere(
          (track) => track?['track_id'] == id,
          orElse: () => null,
        ),
      )
      .whereType<Map<String, dynamic>>()
      .toList();

  @override
  void dispose() {
    _uploadProgressTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final showSections = _search.text.trim().isEmpty;
    final recentKeys = _recent.map(_trackKey).toSet();
    final recommendations = visible
        .where((track) => !recentKeys.contains(_trackKey(track)))
        .toList();
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('GhostSound'),
        backgroundColor: Colors.transparent,
        actions: [
          if (_account != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  '@$_account',
                  style: TextStyle(color: GE.sub, fontSize: 12),
                ),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 30),
              children: [
                _catalogIntro(),
                const SizedBox(height: 12),
                TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Найти в GhostSound',
                    prefixIcon: const Icon(CupertinoIcons.search),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            onPressed: _search.clear,
                            icon: const Icon(CupertinoIcons.clear),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                if (_error != null)
                  GlassCard(
                    lite: true,
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!),
                  ),
                if (widget.remaining > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _uploadCard(),
                  ),
                if (showSections && _recent.isNotEmpty) ...[
                  _section('Недавно слушали'),
                  for (final track in _recent) _catalogTile(track),
                  _section('Рекомендации'),
                  for (final track in recommendations) _catalogTile(track),
                ] else if (showSections) ...[
                  _section('Рекомендации'),
                  for (final track in recommendations) _catalogTile(track),
                ],
                if (showSections &&
                    _recent.isNotEmpty &&
                    recommendations.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text(
                        'Каталог пока пуст',
                        style: TextStyle(color: GE.sub),
                      ),
                    ),
                  )
                else if (!showSections && visible.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text(
                        'Ничего не найдено',
                        style: TextStyle(color: GE.sub),
                      ),
                    ),
                  )
                else if (!showSections)
                  for (final track in visible) _catalogTile(track),
              ],
            ),
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
    child: Text(
      title,
      style: TextStyle(
        color: GE.text,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _catalogIntro() => GlassCard(
    radius: 24,
    padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
    fillOverride: GE.surface.withValues(alpha: 0.58),
    blurOverride: 22,
    ignoreSurfaceToggle: true,
    child: Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
          ),
          child: const Icon(CupertinoIcons.music_note_2, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Музыка в профиле',
                style: TextStyle(
                  color: GE.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'Выбери до ${widget.remaining} треков. Они будут доступны прямо из профиля.',
                style: TextStyle(color: GE.sub, fontSize: 12, height: 1.3),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _uploadCard() => GlassCard(
    radius: 18,
    padding: const EdgeInsets.fromLTRB(13, 11, 8, 11),
    fillOverride: GE.primary.withValues(alpha: 0.11),
    onTap: _uploading ? null : _upload,
    child: Row(
      children: [
        Icon(CupertinoIcons.cloud_upload, color: GE.primary, size: 25),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Загрузить свой файл',
                style: TextStyle(color: GE.text, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                _uploading
                    ? _uploadProgress >= 0.94
                          ? 'Обработка файла… ${(_uploadProgress * 100).round()}%'
                          : 'Отправка ${(_uploadProgress * 100).round()}%'
                    : 'MP3, M4A, WAV или OGG · до 15 МБ',
                style: TextStyle(color: GE.sub, fontSize: 11),
              ),
              if (_uploading) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    value: _uploadProgress == 0 ? null : _uploadProgress,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 4),
        Icon(
          _uploading ? CupertinoIcons.hourglass : CupertinoIcons.chevron_right,
          color: GE.sub,
          size: 18,
        ),
      ],
    ),
  );

  Widget _catalogTile(Map<String, dynamic> track) {
    return AnimatedBuilder(
      animation: GlobalAudioPlayer.instance,
      builder: (context, _) {
        final player = GlobalAudioPlayer.instance;
        final active = _trackKey(player.currentTrack) == _trackKey(track);
        return Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child: GlassCard(
            lite: true,
            padding: const EdgeInsets.all(9),
            fillOverride: active ? GE.primary.withValues(alpha: 0.13) : null,
            onTap: () async {
              await GlobalAudioPlayer.instance.playQueue(_withSource([track]));
              await _remember(track);
            },
            child: Row(
              children: [
                _cover(track['cover_url'] as String?),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _text(track['name'], 'Без названия'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: GE.text,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      Text(
                        _text(track['artist'], 'Неизвестный исполнитель'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: GE.sub,
                          fontSize: 13,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      if (_durationText(track).isNotEmpty)
                        Text(
                          _durationText(track),
                          style: TextStyle(color: GE.sub, fontSize: 10),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: active && player.isPlaying ? 'Пауза' : 'Прослушать',
                  onPressed: () async {
                    if (active) {
                      await player.toggle();
                    } else {
                      await player.playQueue(_withSource([track]));
                      await _remember(track);
                    }
                  },
                  icon: Icon(
                    active && player.isPlaying
                        ? CupertinoIcons.pause_fill
                        : CupertinoIcons.play_fill,
                    color: active ? GE.primary : GE.sub,
                    size: 18,
                  ),
                ),
                IconButton(
                  tooltip: 'Добавить в профиль',
                  onPressed: widget.remaining <= 0
                      ? null
                      : () => Navigator.pop(
                          context,
                          Map<String, dynamic>.from(track)
                            ..remove('_catalog_id'),
                        ),
                  icon: Icon(CupertinoIcons.plus_circle, color: GE.primary),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _cover(String? value) {
    final url = value == null || value.isEmpty ? null : _absolute(value);
    return ClipRRect(
      borderRadius: BorderRadius.circular(11),
      child: SizedBox(
        width: 54,
        height: 54,
        child: url == null
            ? ColoredBox(
                color: GE.primary.withValues(alpha: 0.16),
                child: Icon(CupertinoIcons.music_note_2, color: GE.primary),
              )
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: GE.primary.withValues(alpha: 0.16),
                  child: Icon(CupertinoIcons.music_note_2, color: GE.primary),
                ),
              ),
      ),
    );
  }

  String _absolute(String value) =>
      value.startsWith('http') ? value : '${GE.baseUrl}$value';

  String _text(Object? value, String fallback) {
    final result = value?.toString().trim() ?? '';
    return result.isEmpty ? fallback : result;
  }

  String _durationText(Map<String, dynamic> track) {
    final raw = track['duration_ms'];
    final milliseconds = raw is num ? raw.round() : int.tryParse('$raw') ?? 0;
    if (milliseconds <= 0) return '';
    final seconds = milliseconds ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  String _trackKey(Map<String, dynamic>? track) => track == null
      ? ''
      : '${track['source'] ?? 'local'}:${track['track_id'] ?? track['url'] ?? track['name']}';

  List<Map<String, dynamic>> _withSource(List<Map<String, dynamic>> source) =>
      source
          .map((track) => {...track, '_audio_source': 'catalog_preview'})
          .toList();

  String _mime(String name) {
    return switch (name.split('.').last.toLowerCase()) {
      'm4a' => 'audio/mp4',
      'wav' => 'audio/wav',
      'ogg' => 'audio/ogg',
      _ => 'audio/mpeg',
    };
  }
}
