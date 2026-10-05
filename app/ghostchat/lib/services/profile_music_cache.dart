import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persistent cache for tracks that are played from a user profile.
///
/// Profile music is marked by ProfileMusicPlayer with `_audio_source:
/// profile_music`. The cache deliberately does not handle catalog previews:
/// those are short-lived network previews and should not fill device storage.
class ProfileMusicCache {
  ProfileMusicCache._();

  static final ProfileMusicCache instance = ProfileMusicCache._();

  final Map<String, String> _memoryPaths = {};
  final Map<String, Future<String?>> _downloads = {};
  Directory? _directory;

  bool handles(Map<String, dynamic> track) =>
      track['_audio_source']?.toString() == 'profile_music';

  /// Returns a cached file path, checking the persistent app directory when
  /// this track has not been seen during the current process yet.
  Future<String?> pathFor(Map<String, dynamic> track) async {
    if (!handles(track)) return null;
    final key = cacheKey(track);
    final memoryPath = _memoryPaths[key];
    if (memoryPath != null) {
      final file = File(memoryPath);
      if (await file.exists() && await file.length() > 0) return memoryPath;
      _memoryPaths.remove(key);
    }

    final file = await _fileFor(track);
    if (await file.exists() && await file.length() > 0) {
      _memoryPaths[key] = file.path;
      return file.path;
    }
    return null;
  }

  /// Downloads a profile track once. Every caller receives the same in-flight
  /// Future, so opening the profile repeatedly cannot start duplicate downloads.
  Future<String?> download(Map<String, dynamic> track, List<String> urls) {
    if (!handles(track) || urls.isEmpty) return Future<String?>.value();
    final key = cacheKey(track);
    final active = _downloads[key];
    if (active != null) return active;
    final future = _download(track, urls);
    _downloads[key] = future;
    future.then<void>(
      (_) => _downloads.remove(key),
      onError: (Object _, StackTrace __) => _downloads.remove(key),
    );
    return future;
  }

  /// Stable key includes the profile owner, track identity and source. If a
  /// server replaces a file behind a different URL, it gets a new cache file.
  String cacheKey(Map<String, dynamic> track) {
    final owner = track['_audio_profile_username']?.toString().trim() ?? '';
    final identity = _first(track, const [
      'track_id',
      'id',
      'ID',
      'slug',
      'track_slug',
      'trackSlug',
      'url',
      'audio_url',
      'audioUrl',
      'name',
    ]);
    final source = _first(track, const [
      'url',
      'audio_url',
      'audioUrl',
      'stream_url',
      'streamUrl',
      'path',
      'src',
      'slug',
    ]);
    return _fnv1a('$owner|$identity|$source');
  }

  Future<String?> _download(
    Map<String, dynamic> track,
    List<String> urls,
  ) async {
    final file = await _fileFor(track);
    if (await file.exists() && await file.length() > 0) {
      _memoryPaths[cacheKey(track)] = file.path;
      return file.path;
    }

    final temporary = File('${file.path}.part');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30);
    try {
      for (final url in urls) {
        try {
          if (await temporary.exists()) await temporary.delete();
          final request = await client.getUrl(Uri.parse(url));
          request.followRedirects = true;
          final response = await request.close().timeout(
            const Duration(seconds: 20),
          );
          if (response.statusCode != HttpStatus.ok) {
            await response.drain<void>();
            continue;
          }

          final sink = temporary.openWrite();
          try {
            await for (final chunk in response.timeout(
              const Duration(seconds: 45),
            )) {
              sink.add(chunk);
            }
            await sink.close();
          } catch (_) {
            await sink.close();
            rethrow;
          }

          if (await temporary.length() <= 0) continue;
          if (await file.exists()) await file.delete();
          final saved = await temporary.rename(file.path);
          _memoryPaths[cacheKey(track)] = saved.path;
          return saved.path;
        } catch (_) {
          // Try the next source candidate; playback itself already has the
          // same fallback behavior.
          try {
            if (await temporary.exists()) await temporary.delete();
          } catch (_) {}
        }
      }
    } finally {
      client.close(force: true);
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {}
    }
    return null;
  }

  Future<File> _fileFor(Map<String, dynamic> track) async {
    final directory = await _directoryFor();
    return File(
      '${directory.path}/track_${cacheKey(track)}${_extension(track)}',
    );
  }

  Future<Directory> _directoryFor() async {
    final current = _directory;
    if (current != null) return current;
    final appSupport = await getApplicationSupportDirectory();
    final support = Directory('${appSupport.path}/profile_music_cache');
    if (!await support.exists()) await support.create(recursive: true);
    _directory = support;
    return support;
  }

  String _extension(Map<String, dynamic> track) {
    final mime = _first(track, const [
      'mime',
      'Mime',
      'mime_type',
    ]).toLowerCase();
    if (mime.contains('ogg')) return '.ogg';
    if (mime.contains('wav')) return '.wav';
    if (mime.contains('mp4') || mime.contains('m4a')) return '.m4a';
    if (mime.contains('aac')) return '.aac';
    if (mime.contains('webm')) return '.webm';
    final source = _first(track, const [
      'url',
      'audio_url',
      'audioUrl',
      'stream_url',
      'streamUrl',
      'path',
      'src',
      'slug',
    ]).toLowerCase().split('?').first.split('#').first;
    if (source.endsWith('.wav')) return '.wav';
    if (source.endsWith('.m4a') || source.endsWith('.mp4')) return '.m4a';
    if (source.endsWith('.aac')) return '.aac';
    if (source.endsWith('.webm')) return '.webm';
    if (source.endsWith('.ogg') || source.endsWith('.oga')) return '.ogg';
    // GhostSound profile streams are OGG even when the payload only exposes
    // a slug/id rather than a filename.
    return '.ogg';
  }

  String _first(Map<String, dynamic> track, List<String> keys) {
    for (final key in keys) {
      final value = track[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  String _fnv1a(String value) {
    var hash = 0x811C9DC5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
