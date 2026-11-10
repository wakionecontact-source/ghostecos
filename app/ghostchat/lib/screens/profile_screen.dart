// ProfileScreen — полный профиль юзера: шапка с аватаром / именем /
// статусом / репутацией, статы (постов/подписчиков/подписок/лайков),
// кнопки follow + написать, лента собственных постов с подгрузкой.
//
// API: /prof/{username} → инфо + первые 15 постов
//      /user/{username}/feed_combined → посты + репосты в хронологии
//      /prof/{username}/posts?offset=N → пагинация
//      POST /follow/{username} / DELETE /follow/{username}
import 'dart:async';
import 'package:file_selector/file_selector.dart' as fs;
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../services/public_page_link.dart';
import '../mesh_background.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/chat_repo.dart';
import '../services/contact_service.dart';
import '../services/optimistic_action.dart';
import '../services/profile_cache.dart';
import '../widgets/avatar.dart';
import '../widgets/call_widget.dart';
import '../services/theme_service.dart';
import '../widgets/glass.dart';
import '../widgets/skeleton.dart';
import '../widgets/toast_overlay.dart';
import '../widgets/emoji_text.dart';
import '../core/local/app_logger.dart';
import '../widgets/error_panel.dart';
import '../widgets/profile_banner.dart';
import '../widgets/profile_music_player.dart';
import '../widgets/bot_badge.dart';
import 'profile_music_library_screen.dart';
import 'chat_screen.dart';
import 'chat_picker_screen.dart';

class ProfileScreen extends StatefulWidget {
  final String username;

  /// The embedded profile tab is always the signed-in user's own profile.
  /// This avoids showing foreign-profile actions for one frame when a shared
  /// cache entry does not yet contain the server-only `is_me` flag.
  final bool isOwn;

  /// true — встроен в MainShell (свой профиль в wide-раскладке), без своего
  /// back-стрелки и без MeshBackground (родитель уже даёт фон).
  final bool embedded;
  final bool openMusicLibrary;
  const ProfileScreen({
    super.key,
    required this.username,
    this.isOwn = false,
    this.embedded = false,
    this.openMusicLibrary = false,
  });
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _api = ApiClient();
  final _scroll = ScrollController();
  // Инициализируем сразу из СИНХРОННОГО in-memory кэша (см. profile_cache.dart)
  // — если профиль уже открывали в этой сессии, первый же build() выходит
  // с готовыми данными, без единого кадра skeleton (раньше даже "быстрый"
  // async-кэш из SharedPreferences всё равно на миг мелькал загрузкой из-за
  // неизбежного кадра задержки на await).
  late Map<String, dynamic>? _profile = ProfileCache.instance.getProfileSync(
    widget.username,
  );
  late List<Map<String, dynamic>> _items =
      ProfileCache.instance.getPostsSync(widget.username) ?? [];
  late bool _loading = _profile == null;
  String? _error;
  String? _errorDetails;
  int? _errorLogId;
  bool _loadingMore = false;
  bool _exhausted = false;
  String? _myUsername;
  String? _cachedOwnUserId;
  bool _followBusy = false;
  bool _isContact = false;
  bool _contactStateReady = false;
  bool _contactBusy = false;
  bool _thoughtBusy = false;
  bool _bannerBusy = false;
  // Kept only for the legacy editor migration path; the visible profile card
  // now opens ProfileMusicLibraryScreen instead.
  bool _musicBusy = false;
  bool _didOpenMusicLibrary = false;
  Timer? _thoughtExpiryTimer;

  bool get _isMe => widget.isOwn || (_profile?['is_me'] as bool?) == true;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    if (widget.isOwn) unawaited(_loadCachedOwnUserId());
    if (!widget.isOwn) unawaited(_loadContactState());
    if (_profile != null) {
      _scheduleThoughtExpiry();
      // Уже тёплый in-memory кэш (этот профиль открывали в текущей сессии
      // приложения) — сеть дёргаем в фоне, без похода на диск.
      _load();
    } else {
      // Холодный старт (первое открытие ЭТОГО процесса приложения) — в
      // памяти пусто, но на диске (SharedPreferences) может быть сохранённый
      // профиль с прошлого запуска. Приложение офлайн-first — без интернета
      // должны показать хотя бы то, что сохранено, а не вечный skeleton.
      _loadFromDiskThenNetwork();
    }
  }

  Future<void> _loadCachedOwnUserId() async {
    final value = await AuthService.userId();
    if (mounted && value != null && value.isNotEmpty) {
      setState(() => _cachedOwnUserId = value);
    }
  }

  Future<void> _loadFromDiskThenNetwork() async {
    final cachedProfile = await ProfileCache.instance.getProfile(
      widget.username,
    );
    if (cachedProfile != null && mounted) {
      final cachedPosts = await ProfileCache.instance.getPosts(widget.username);
      if (mounted) {
        setState(() {
          _profile = cachedProfile;
          _items = cachedPosts ?? [];
          _loading = false;
        });
        _scheduleThoughtExpiry();
      }
    }
    await _load();
  }

  Future<void> _load() async {
    try {
      _myUsername = await AuthService.username();
      final p = await _api.socGet('/prof/${widget.username}');
      if (!mounted) return;
      if (p is Map && p['is_bot'] == true) {
        unawaited(() async {
          try {
            if (await ChatRepo.instance.isPeerBot(widget.username)) {
              await ChatRepo.instance.refreshPeerBotStatus(widget.username);
            }
          } catch (_) {}
        }());
      }
      List<Map<String, dynamic>> items = [];
      // Подтянем combined-ленту с репостами параллельно
      try {
        final feed = await _api.socGet(
          '/user/${widget.username}/feed_combined',
          {'limit': 40},
        );
        if (feed is List) {
          items = feed
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
        }
      } catch (_) {
        // Fallback на posts из /prof
        if (p is Map && p['posts'] is List) {
          items = (p['posts'] as List)
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
        }
      }
      final profile = Map<String, dynamic>.from(p as Map);
      if (widget.isOwn || profile['is_me'] == true) {
        final serverId = _profileId(profile, fallback: '').trim();
        if (serverId.isNotEmpty && serverId != widget.username) {
          _cachedOwnUserId = serverId;
          unawaited(AuthService.updateCachedProfile(userId: serverId));
        }
      }
      final cachedAbout = _profile?['about'];
      // Старый backend мог вернуть профиль без поля about. Не даём такому
      // ответу затереть уже сохранённое значение в памяти и на диске.
      if (profile['about'] == null &&
          cachedAbout is String &&
          cachedAbout.trim().isNotEmpty) {
        profile['about'] = cachedAbout;
      }
      setState(() {
        _profile = profile;
        _items = items;
        _loading = false;
        _error = null;
        _errorDetails = null;
        _errorLogId = null;
      });
      ProfileCache.instance.setProfile(widget.username, profile);
      ProfileCache.instance.setPosts(widget.username, items);
      _scheduleThoughtExpiry();
      _openRequestedMusicLibrary();
    } catch (e) {
      if (!mounted) return;
      final details = errorDetails(e);
      final entry = appLog.error(
        'profile',
        'Profile load failed username=${widget.username}: $details',
      );
      setState(() {
        _loading = false;
        // Не теряем уже показанный кэш. Если его совсем нет, создаём
        // минимальный профиль, чтобы пользователь всё равно видел username.
        _profile ??= {
          'display_name': widget.username,
          'about': '',
          'avatar_url': null,
          'is_me': false,
          'posts_count': 0,
          'followers_count': 0,
          'following_count': 0,
          'likes_received': 0,
          'reputation_score': 0,
          'reputation_band': 'mid',
          'posts': <Map<String, dynamic>>[],
        };
        _error = errorSummary(e, fallback: 'Не удалось обновить профиль');
        _errorDetails = details;
        _errorLogId = entry.id;
      });
      toast.show(
        'Не удалось обновить профиль',
        level: ToastLevel.error,
        logId: entry.id,
      );
    }
  }

  void _openRequestedMusicLibrary() {
    if (!widget.openMusicLibrary || _didOpenMusicLibrary || !mounted) return;
    _didOpenMusicLibrary = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openMusicLibrary();
    });
  }

  void _onScroll() {
    if (_loadingMore || _exhausted) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _exhausted) return;
    _loadingMore = true;
    try {
      final r = await _api.socGet('/prof/${widget.username}/posts', {
        'offset': _items.length,
      });
      if (r is List) {
        if (r.isEmpty) {
          _exhausted = true;
        } else {
          final more = r
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
          setState(() => _items = [..._items, ...more]);
        }
      }
    } catch (_) {
    } finally {
      _loadingMore = false;
    }
  }

  @override
  void dispose() {
    _thoughtExpiryTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  int? _dailyThoughtExpiresAt(Map<String, dynamic> profile) {
    if (profile['daily_status_eternal'] == true) return null;
    final rawExpiry = profile['daily_status_expires_at'];
    if (rawExpiry is num) return rawExpiry.toInt();
    final rawSetAt = profile['daily_status_set_at'];
    final setAt = rawSetAt is num
        ? rawSetAt.toInt()
        : int.tryParse(rawSetAt?.toString() ?? '');
    return setAt == null || setAt <= 0 ? null : setAt + 86400;
  }

  void _scheduleThoughtExpiry() {
    _thoughtExpiryTimer?.cancel();
    final profile = _profile;
    if (profile == null || profile['daily_status_eternal'] == true) return;
    final expiresAt = _dailyThoughtExpiresAt(profile);
    if (expiresAt == null) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final remaining = expiresAt - now;
    if (remaining <= 0) return;
    _thoughtExpiryTimer = Timer(Duration(seconds: remaining + 1), () {
      if (mounted) setState(() {});
    });
  }

  // Оптимистично — кнопка и счётчик переключаются мгновенно, без спиннера
  // (сам смысл "механики майнкрафта": ждать нечего, состояние уже верное).
  // _followBusy остаётся только как защита от дабл-тапа, пока запрос летит.
  Future<void> _toggleFollow() async {
    if (_followBusy || _profile == null) return;
    _followBusy = true;
    final wasFollowing = (_profile!['am_following'] as bool?) ?? false;
    try {
      await optimisticAction(
        apply: () {
          HapticFeedback.selectionClick();
          setState(() {
            _profile!['am_following'] = !wasFollowing;
            _profile!['followers_count'] =
                ((_profile!['followers_count'] as num?) ?? 0).toInt() +
                (wasFollowing ? -1 : 1);
          });
        },
        request: () async {
          if (wasFollowing) {
            await _api.socDelete('/follow/${widget.username}');
          } else {
            await _api.socPost('/follow/${widget.username}');
          }
        },
        undo: () {
          setState(() {
            _profile!['am_following'] = wasFollowing;
            _profile!['followers_count'] =
                ((_profile!['followers_count'] as num?) ?? 0).toInt() +
                (wasFollowing ? 1 : -1);
          });
        },
        failureMessage: 'Не вышло',
      );
    } catch (_) {
      // no-op — уже отработано в optimisticAction
    } finally {
      _followBusy = false;
    }
  }

  Future<void> _loadContactState() async {
    try {
      final contacts = await ContactService.instance.list();
      final normalizedUsername = widget.username.trim().toLowerCase();
      if (!mounted) return;
      setState(() {
        _isContact = contacts.any(
          (contact) =>
              contact.username.trim().toLowerCase() == normalizedUsername,
        );
        _contactStateReady = true;
      });
    } catch (_) {
      // Contact actions are optional and must not block profile loading.
    }
  }

  Future<void> _addProfileToContacts() async {
    if (_contactBusy || _isContact || _isMe || _profile?['is_bot'] == true) {
      if (_profile?['is_bot'] == true) {
        toast.show('Ботов нельзя добавлять в контакты');
      }
      return;
    }
    setState(() => _contactBusy = true);
    try {
      final profile = _profile;
      await ContactService.instance.add(
        username: widget.username,
        displayName: profile?['display_name'] as String? ?? widget.username,
        avatarUrl: profile?['avatar_url'] as String?,
      );
      if (!mounted) return;
      setState(() {
        _isContact = true;
        _contactStateReady = true;
      });
      toast.show(
        '${profile?['display_name'] ?? widget.username} теперь в контактах',
      );
    } catch (error) {
      if (mounted) toast.show('Не удалось добавить контакт: $error');
    } finally {
      if (mounted) setState(() => _contactBusy = false);
    }
  }

  Future<void> _editBanner() async {
    if (!_isMe || _bannerBusy) return;
    final result = await showProfileBannerEditor(
      context,
      initial: ProfileBannerConfig.fromDynamic(_profile?['banner']),
    );
    if (result == null || !mounted) return;
    setState(() => _bannerBusy = true);
    try {
      final response = await _api.updateOwnProfile(
        banner: result.clear ? null : result.config!.toJson(),
        clearBanner: result.clear,
      );
      if (!mounted) return;
      final next = Map<String, dynamic>.from(_profile ?? const {});
      next['banner'] = response['banner'];
      setState(() {
        _profile = next;
        _bannerBusy = false;
      });
      ProfileCache.instance.setProfile(widget.username, next);
      toast.show(result.clear ? 'Баннер убран' : 'Баннер сохранён');
    } catch (error) {
      if (!mounted) return;
      setState(() => _bannerBusy = false);
      toast.show('Не удалось сохранить баннер: $error');
    }
  }

  Future<void> _editMusic() async {
    if (!_isMe || _musicBusy) return;
    final current = _profile?['profile_music'] is Map
        ? Map<String, dynamic>.from(_profile!['profile_music'] as Map)
        : null;
    final draft = await _showProfileMusicEditor(context, initial: current);
    if (draft == null || !mounted) return;
    if (draft.audio == null && current == null) {
      toast.show('Выберите аудиофайл', level: ToastLevel.error);
      return;
    }

    setState(() => _musicBusy = true);
    try {
      var url = current?['url'] as String?;
      if (draft.audio != null) {
        final bytes = await draft.audio.readAsBytes();
        if (bytes.length > 15 * 1024 * 1024) {
          throw Exception('Аудиофайл больше 15 МБ');
        }
        final uploaded = await _api.uploadSocFile(
          bytes: bytes,
          filename: draft.audio.name as String,
          mime: _profileMusicMime(draft.audio.name as String),
        );
        if (uploaded['type'] != 'audio' || uploaded['url'] is! String) {
          throw Exception('Сервер не принял аудиофайл');
        }
        url = uploaded['url'] as String;
      }

      String? coverUrl = current?['cover_url'] as String?;
      if (draft.coverChanged) {
        coverUrl = null;
        if (draft.cover != null) {
          final coverBytes = await draft.cover.readAsBytes();
          if (coverBytes.length > 5 * 1024 * 1024) {
            throw Exception('Обложка больше 5 МБ');
          }
          final uploaded = await _api.uploadSocFile(
            bytes: coverBytes,
            filename: draft.cover.name as String,
            mime: draft.cover.mimeType as String?,
          );
          if (uploaded['type'] != 'image' || uploaded['url'] is! String) {
            throw Exception('Сервер не принял обложку');
          }
          coverUrl = uploaded['url'] as String;
        }
      }

      final response = await _api.updateOwnProfile(
        profileMusic: {
          'url': url,
          'name': draft.name,
          'artist': draft.artist,
          'album': draft.album,
          if (coverUrl != null) 'cover_url': coverUrl,
        },
      );
      if (!mounted) return;
      final next = Map<String, dynamic>.from(_profile ?? const {});
      next['profile_music'] = response['profile_music'];
      setState(() {
        _profile = next;
        _musicBusy = false;
      });
      ProfileCache.instance.setProfile(widget.username, next);
      toast.show('Музыка профиля сохранена');
    } catch (error) {
      if (!mounted) return;
      setState(() => _musicBusy = false);
      toast.show(
        'Не удалось сохранить музыку: $error',
        level: ToastLevel.error,
      );
    }
  }

  Future<void> _editDailyThought({
    required String? initialText,
    required String? initialMood,
  }) async {
    if (!_isMe) return;
    final controller = TextEditingController(text: initialText ?? '');
    var mood = initialMood ?? 'joy';
    const moods = <({String emoji, String value})>[
      (emoji: '🙂', value: 'joy'),
      (emoji: '🔥', value: 'fire'),
      (emoji: '❤️', value: 'love'),
      (emoji: '😴', value: 'tired'),
      (emoji: '🧊', value: 'chill'),
      (emoji: '😮', value: 'surprised'),
    ];
    try {
      final result = await showDialog<Map<String, String?>>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: GE.bgDeep,
            title: const Text('Мысль дня'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    maxLength: 50,
                    maxLines: 1,
                    decoration: const InputDecoration(
                      hintText: 'Что у тебя сегодня в голове?',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Настроение',
                    style: TextStyle(color: GE.sub, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final item in moods)
                        ChoiceChip(
                          label: Text(item.emoji),
                          selected: mood == item.value,
                          onSelected: (_) =>
                              setDialogState(() => mood = item.value),
                          showCheckmark: false,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              if (initialText != null && initialText.isNotEmpty)
                TextButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, {'delete': '1'}),
                  child: Text('Удалить', style: TextStyle(color: GE.red)),
                ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, {
                  'text': controller.text.trim(),
                  'mood': mood,
                }),
                child: const Text('Опубликовать'),
              ),
            ],
          ),
        ),
      );
      if (result == null || !mounted) return;
      if (result['delete'] == '1') {
        await _api.socDelete('/status/my');
        if (!mounted) return;
        final next = Map<String, dynamic>.from(_profile ?? const {});
        next.remove('daily_status');
        next.remove('daily_status_mood');
        next.remove('daily_status_set_at');
        next.remove('daily_status_expires_at');
        setState(() => _profile = next);
        ProfileCache.instance.setProfile(widget.username, next);
        return;
      }
      final text = result['text']?.trim() ?? '';
      if (text.isEmpty) {
        toast.show('Мысль не может быть пустой');
        return;
      }
      final response = await _api.socPost('/status/set', {
        'text': text,
        'mood': result['mood'],
      });
      if (!mounted) return;
      final next = Map<String, dynamic>.from(_profile ?? const {});
      next['daily_status'] = response['text'] ?? text;
      next['daily_status_mood'] = response['mood'] ?? result['mood'];
      next['daily_status_set_at'] = response['set_at'];
      next['daily_status_expires_at'] = response['expires_at'];
      setState(() => _profile = next);
      ProfileCache.instance.setProfile(widget.username, next);
      _scheduleThoughtExpiry();
    } catch (error) {
      if (mounted) toast.show('Не удалось сохранить мысль: $error');
    } finally {
      controller.dispose();
    }
  }

  Future<void> _toggleThoughtLike() async {
    if (_thoughtBusy || _profile == null) return;
    setState(() => _thoughtBusy = true);
    try {
      final response = await _api.socPost(
        '/status/${Uri.encodeComponent(widget.username)}/like',
        const {},
      );
      if (!mounted) return;
      final next = Map<String, dynamic>.from(_profile!);
      next['liked_by_me'] = response['liked'] == true;
      next['likes_count'] = response['likes_count'] ?? 0;
      setState(() {
        _profile = next;
        _thoughtBusy = false;
      });
      ProfileCache.instance.setProfile(widget.username, next);
    } catch (error) {
      if (!mounted) return;
      setState(() => _thoughtBusy = false);
      toast.show('Не удалось изменить лайк мысли', level: ToastLevel.error);
    }
  }

  Future<void> _shareThought(String text, {required int expiresAt}) async {
    final selected = await Navigator.of(context).push<Set<String>>(
      MaterialPageRoute(
        builder: (_) => const ChatPickerScreen(title: 'Поделиться мыслью'),
      ),
    );
    if (!mounted || selected == null || selected.isEmpty) return;
    var sent = 0;
    for (final peer in selected) {
      if (peer.startsWith('lan:') || peer.startsWith('bm:')) continue;
      try {
        if (await ChatRepo.instance.isPeerBot(peer)) continue;
        await ChatRepo.instance.sendDmText(
          peer,
          '💭 $text',
          forwardedFrom: widget.username,
          forwardedThoughtExpiresAt: expiresAt,
        );
        sent++;
      } catch (error) {
        appLog.warn('profile', 'Thought share failed for @$peer: $error');
      }
    }
    if (mounted) {
      toast.show(
        sent > 0
            ? 'Мысль отправлена в $sent чат(а)'
            : 'Не удалось отправить мысль',
      );
    }
  }

  Future<void> _removeMusic() async {
    if (!_isMe || _musicBusy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Убрать музыку?'),
        content: const Text('Музыка исчезнет из профиля.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Убрать'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _musicBusy = true);
    try {
      final response = await _api.updateOwnProfile(clearMusic: true);
      if (!mounted) return;
      final next = Map<String, dynamic>.from(_profile ?? const {});
      next['profile_music'] = response['profile_music'];
      setState(() {
        _profile = next;
        _musicBusy = false;
      });
      ProfileCache.instance.setProfile(widget.username, next);
      toast.show('Музыка профиля убрана');
    } catch (error) {
      if (!mounted) return;
      setState(() => _musicBusy = false);
      toast.show('Не удалось убрать музыку: $error', level: ToastLevel.error);
    }
  }

  String _profileMusicMime(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'm4a' => 'audio/mp4',
      'wav' => 'audio/wav',
      'ogg' => 'audio/ogg',
      _ => 'audio/mpeg',
    };
  }

  Future<void> _openMusicLibrary() async {
    final tracks = _musicList(_profile?['profile_music']);
    final banner = ProfileBannerConfig.fromDynamic(_profile?['banner']);
    final result = await Navigator.push<Object?>(
      context,
      MaterialPageRoute(
        builder: (_) => ProfileMusicLibraryScreen(
          tracks: tracks,
          isOwner: _isMe,
          banner: banner,
          sourceProfileUsername: widget.username,
        ),
      ),
    );
    if (!mounted || result is! List) return;
    final next = Map<String, dynamic>.from(_profile ?? const {});
    next['profile_music'] = result
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .take(3)
        .toList();
    setState(() => _profile = next);
    ProfileCache.instance.setProfile(widget.username, next);
  }

  List<Map<String, dynamic>> _musicList(Object? raw) {
    if (raw is Map) return [Map<String, dynamic>.from(raw)];
    if (raw is! List) return [];
    return raw.whereType<Map>().map(Map<String, dynamic>.from).take(3).toList();
  }

  String _profileId(Map<String, dynamic> profile, {required String fallback}) {
    for (final key in const ['id', 'user_id', 'uid']) {
      final value = profile[key]?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    // embedded=true — уже внутри MainShell, у которого один персистентный
    // MeshBackground на все три вкладки; свой вложенный фон означал бы
    // пересоздание mesh-анимации заново при каждом возврате на вкладку.
    if (widget.embedded) return _scaffold(context);
    return MeshBackground(
      callWidgetPlacement: CallWidgetPlacement.bottom,
      callWidgetStyle: CallWidgetStyle.compact,
      child: _scaffold(context),
    );
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: widget.embedded
          ? null
          : GlassAppBar(showBack: true, titleText: 'Профиль'),
      body: RefreshIndicator(
        color: GE.primary,
        onRefresh: () async {
          if (_profile == null) setState(() => _loading = true);
          await _load();
        },
        // Плавный переход skeleton → контент — раньше загрузка сменялась
        // профилем резким скачком.
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: _loading
              ? ListView(
                  key: const ValueKey('skeleton'),
                  physics: const NeverScrollableScrollPhysics(),
                  children: const [
                    SkeletonProfileHeader(),
                    SkeletonRow(avatarSize: 32),
                    SkeletonRow(avatarSize: 32),
                    SkeletonRow(avatarSize: 32),
                  ],
                )
              : KeyedSubtree(
                  key: const ValueKey('content'),
                  child: _error != null && _profile == null
                      ? _errorView()
                      : _body(),
                ),
        ),
      ),
    );
  }

  Widget _errorView() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 80),
        AppErrorPanel(
          title: 'Профиль не загрузился',
          message: _error ?? 'Не удалось получить данные профиля',
          details: _errorDetails,
          logId: _errorLogId,
          onRetry: _load,
        ),
      ],
    );
  }

  Widget _body() {
    final p = _profile!;
    final profileHidden = p['profile_hidden'] == true;
    final displayNameHidden = p['display_name_hidden'] == true;
    final displayName = profileHidden
        ? 'Скрыто'
        : (p['display_name'] as String?) ?? widget.username;
    final visibleUsername = p['username'] as String?;
    final repScore = (p['reputation_score'] as num?)?.toInt() ?? 100;
    final repBand = (p['reputation_band'] as String?) ?? 'mid';
    final dailyThoughtExpiresAt = _dailyThoughtExpiresAt(p);
    final dailyThoughtActive =
        p['daily_status_eternal'] == true ||
        (dailyThoughtExpiresAt != null &&
            DateTime.now().millisecondsSinceEpoch ~/ 1000 <
                dailyThoughtExpiresAt);
    final dailyStatus = dailyThoughtActive
        ? p['daily_status'] as String?
        : null;
    final dailyMood = p['daily_status_mood'] as String?;
    final dailyMoodEmoji = dailyThoughtActive
        ? switch (dailyMood) {
            'joy' => '😊',
            'sad' => '😢',
            'fire' => '🔥',
            'love' => '❤️',
            'tired' => '😴',
            'chill' => '🧊',
            'angry' => '😠',
            'surprised' => '😮',
            _ => null,
          }
        : null;
    final thoughtLikes = (p['likes_count'] as num?)?.toInt() ?? 0;
    final thoughtLiked = p['liked_by_me'] == true;
    final amFollowing = (p['am_following'] as bool?) ?? false;
    final posts = (p['posts_count'] as num?)?.toInt() ?? 0;
    final followers = (p['followers_count'] as num?)?.toInt() ?? 0;
    final following = (p['following_count'] as num?)?.toInt() ?? 0;
    final likes = (p['likes_received'] as num?)?.toInt() ?? 0;
    final profileBanner = profileHidden
        ? null
        : ProfileBannerConfig.fromDynamic(p['banner']) ??
              ProfileBannerConfig.defaultGradient();
    final musicTracks = _musicList(p['profile_music']);

    return ListView(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(
        12,
        12,
        12,
        widget.embedded ? 120 + MediaQuery.of(context).padding.bottom : 80,
      ),
      children: [
        if (widget.embedded) ...[
          _embeddedPageHeader(),
          const SizedBox(height: 18),
        ],
        if (_error != null) ...[
          AppErrorPanel(
            title: 'Показаны сохранённые данные',
            message: _error!,
            details: _errorDetails,
            logId: _errorLogId,
            compact: true,
            onRetry: _load,
          ),
          const SizedBox(height: 10),
        ],
        // Шапка в духе карточки контакта Telegram: большой центрированный
        // аватар + имя + @username, без статов/репутации — тем сюда
        // спускаются ближе к постам (см. ниже), это не главное о человеке.
        ProfileBannerHeader(
          banner: profileBanner,
          avatar: Stack(
            clipBehavior: Clip.none,
            children: [
              GhostAvatar(
                avatarUrl: p['avatar_url'] as String?,
                fallbackText: profileHidden ? '' : displayName,
                fallbackIcon: profileHidden ? CupertinoIcons.person_fill : null,
                size: 96,
              ),
              if (p['is_bot'] == true)
                const Positioned(left: 0, bottom: 0, child: BotBadge(size: 24)),
              if (p['is_bot'] == true)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: ValueListenableBuilder<String?>(
                    valueListenable: ChatRepo.instance.watchBotStatus(
                      widget.username,
                    ),
                    builder: (_, status, __) => Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: (status ?? p['bot_status']) == 'online'
                            ? GE.green
                            : GE.sub.withValues(alpha: 0.55),
                        border: Border.all(color: GE.bg, width: 2),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          identity: Column(
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (p['is_official'] == true) ...[
                    const OfficialBadge(size: 19),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: EmojiText(
                      displayName,
                      allowFormatting: false,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 22,
                        fontWeight: displayNameHidden
                            ? FontWeight.w900
                            : FontWeight.w800,
                        letterSpacing: displayNameHidden ? 1.8 : null,
                        shadows: displayNameHidden
                            ? [
                                Shadow(
                                  color: GE.primary.withValues(alpha: 0.35),
                                  blurRadius: 10,
                                ),
                              ]
                            : null,
                      ),
                    ),
                  ),
                  if (dailyMoodEmoji != null) ...[
                    const SizedBox(width: 5),
                    Text(dailyMoodEmoji, style: const TextStyle(fontSize: 15)),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Text(
                    visibleUsername == null
                        ? 'Юзернейм скрыт'
                        : '@$visibleUsername',
                    style: TextStyle(color: GE.sub, fontSize: 14),
                  ),
                  if (p['is_bot'] == true)
                    ValueListenableBuilder<String?>(
                      valueListenable: ChatRepo.instance.watchBotStatus(
                        widget.username,
                      ),
                      builder: (_, status, __) => BotStatusLabel(
                        status: status ?? p['bot_status'] as String?,
                      ),
                    ),
                ],
              ),
              if ((p['about'] as String?)?.isNotEmpty ?? false) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: EmojiText(
                    p['about'] as String,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: GE.sub, fontSize: 13),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (dailyStatus != null && dailyStatus.isNotEmpty) ...[
          const SizedBox(height: 10),
          _DailyThoughtBubble(
            text: dailyStatus,
            mood: dailyMood,
            likes: thoughtLikes,
            liked: thoughtLiked,
            likeBusy: _thoughtBusy,
            onLike: _toggleThoughtLike,
            onShare: dailyThoughtExpiresAt == null
                ? null
                : () => _shareThought(
                    dailyStatus,
                    expiresAt: dailyThoughtExpiresAt,
                  ),
            onTap: _isMe
                ? () => _editDailyThought(
                    initialText: dailyStatus,
                    initialMood: p['daily_status_mood'] as String?,
                  )
                : null,
          ),
        ] else if (_isMe) ...[
          const SizedBox(height: 10),
          _DailyThoughtBubble(
            text: 'Добавить мысль дня',
            mood: 'joy',
            empty: true,
            onTap: () =>
                _editDailyThought(initialText: null, initialMood: null),
          ),
        ],
        if (musicTracks.isNotEmpty) ...[
          const SizedBox(height: 16),
          ProfileMusicPlayer(
            tracks: musicTracks,
            banner: profileBanner,
            onTap: _openMusicLibrary,
            sourceProfileUsername: widget.username,
          ),
        ] else if (_isMe) ...[
          const SizedBox(height: 16),
          _addMusicCard(profileBanner),
        ],
        const SizedBox(height: 16),
        if (!_isMe) _actionsRow(amFollowing),
        const SizedBox(height: 16),
        // Инфо-строки: как карточка контакта в Telegram — иконка / значение /
        // подпись под ней, а не бейджики вразнобой.
        GlassCard(
          lite: true,
          isListSection: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              _infoRow(
                CupertinoIcons.at,
                visibleUsername == null ? 'Скрыто' : '@$visibleUsername',
                'Имя пользователя',
                onTap: visibleUsername == null
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: visibleUsername));
                        toast.show('Скопировано');
                      },
              ),
              if (_isMe) ...[
                _infoRow(
                  CupertinoIcons.number,
                  _profileId(p, fallback: _cachedOwnUserId ?? widget.username),
                  'ID пользователя',
                  subtle: true,
                  onTap: () {
                    final id = _profileId(
                      p,
                      fallback: _cachedOwnUserId ?? widget.username,
                    );
                    Clipboard.setData(ClipboardData(text: id));
                    toast.show('ID скопирован');
                  },
                ),
              ],
              if (dailyStatus != null && dailyStatus.isNotEmpty) ...[
                Divider(height: 1, color: GE.glassBorder, indent: 48),
                _infoRow(
                  CupertinoIcons.chat_bubble,
                  dailyMood != null && dailyMood.isNotEmpty
                      ? '$dailyMood $dailyStatus'
                      : dailyStatus,
                  'Статус',
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        // GhostSocial-специфика (репутация + статы) — сюда, ближе к постам,
        // а не в самой шапке контакта.
        Row(
          children: [
            ShaderMask(
              shaderCallback: (b) => LinearGradient(
                colors: [GE.primary, GE.primary2],
              ).createShader(b),
              child: const Text(
                'GhostSocial',
                style: TextStyle(
                  color: GE.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const Spacer(),
            _reputationBadge(repScore, repBand),
          ],
        ),
        const SizedBox(height: 10),
        GlassCard(
          lite: true,
          isListSection: true,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              Expanded(
                child: _statCard('Постов', '$posts', CupertinoIcons.doc_text),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statCard(
                  'Подписчики',
                  '$followers',
                  CupertinoIcons.person_2,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statCard(
                  'Подписки',
                  '$following',
                  CupertinoIcons.person_add,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statCard('Лайки', '$likes', CupertinoIcons.heart),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _sectionTitle('Посты'),
        if (_items.isEmpty)
          GlassCard(
            lite: true,
            isListSection: true,
            padding: const EdgeInsets.all(20),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.doc_text, color: GE.sub, size: 32),
                  const SizedBox(height: 6),
                  Text(
                    'Постов пока нет',
                    style: TextStyle(color: GE.sub, fontSize: 13),
                  ),
                ],
              ),
            ),
          )
        else
          for (final it in _items)
            _ProfilePostTile(item: it, myUsername: _myUsername),
        if (_loadingMore)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: CircularProgressIndicator(
                color: GE.primary,
                strokeWidth: 2,
              ),
            ),
          ),
      ],
    );
  }

  Widget _embeddedPageHeader() => Row(
    children: [
      Icon(CupertinoIcons.person_fill, color: GE.primary, size: 22),
      const SizedBox(width: 8),
      Text(
        'Профиль',
        style: TextStyle(
          color: GE.text,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
    ],
  );

  // Telegram-стиль строки контактной инфы: иконка слева, значение сверху,
  // мелкая подпись снизу.
  Widget _addMusicCard(ProfileBannerConfig? banner) {
    return GlassCard(
      radius: 28,
      padding: EdgeInsets.zero,
      fillOverride: Colors.transparent,
      ignoreSurfaceToggle: true,
      onTap: _openMusicLibrary,
      child: SizedBox(
        height: 56,
        child: Stack(
          fit: StackFit.expand,
          children: [
            MirroredProfileBanner(banner: banner, height: 56),
            ColoredBox(color: GE.shadow.withValues(alpha: 0.08)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Icon(
                    CupertinoIcons.music_note_2,
                    color: GE.text.withValues(alpha: 0.82),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Добавить музыку в профиль',
                      style: TextStyle(
                        color: GE.text.withValues(alpha: 0.86),
                        fontSize: 16,
                      ),
                    ),
                  ),
                  Icon(
                    CupertinoIcons.plus,
                    color: GE.text.withValues(alpha: 0.7),
                    size: 20,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(
    IconData icon,
    String value,
    String label, {
    VoidCallback? onTap,
    bool subtle = false,
  }) {
    return PressScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              icon,
              color: subtle ? GE.muted : GE.primary,
              size: subtle ? 16 : 20,
            ),
            SizedBox(width: subtle ? 12 : 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: subtle ? GE.sub : GE.text,
                      fontSize: subtle ? 12.5 : 15,
                      fontWeight: subtle ? FontWeight.w500 : null,
                    ),
                  ),
                  SizedBox(height: subtle ? 1 : 2),
                  Text(
                    label,
                    style: TextStyle(
                      color: GE.muted,
                      fontSize: subtle ? 10.5 : 12,
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

  Widget _reputationBadge(int score, String band) {
    final color = band == 'good'
        ? GE.green
        : (band == 'low' ? GE.red : GE.yellow);
    final label = band == 'good'
        ? 'Хорошая'
        : (band == 'low' ? 'Низкая' : 'Средняя');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: ThemeService.isMinimal
            ? null
            : Border.all(color: color.withValues(alpha: 0.5), width: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.shield, size: 11, color: color),
          const SizedBox(width: 3),
          Text(
            'Репутация $label · $score',
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionsRow(bool following) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: GlassButton(
                label: following ? 'Отписаться' : 'Подписаться',
                icon: following
                    ? CupertinoIcons.person_badge_minus
                    : CupertinoIcons.person_add,
                primary: !following,
                onTap: _toggleFollow,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GlassButton(
                label: 'Написать',
                icon: CupertinoIcons.chat_bubble,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(
                      peer: widget.username,
                      displayName:
                          (_profile!['display_name'] as String?) ??
                          widget.username,
                      isBot: _profile!['is_bot'] == true,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_profile?['is_bot'] != true)
          GlassButton(
            label: _contactStateReady && _isContact
                ? 'В контактах'
                : 'Добавить в контакты',
            icon: _contactStateReady && _isContact
                ? CupertinoIcons.checkmark
                : CupertinoIcons.person_add,
            fullWidth: true,
            onTap: _isContact || _contactBusy ? null : _addProfileToContacts,
          ),
      ],
    );
  }

  Widget _statCard(String label, String value, IconData icon) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: GE.primary, size: 16),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: GE.text,
            fontSize: 16,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: GE.sub, fontSize: 10),
        ),
      ],
    );
  }

  Widget _sectionTitle(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
    child: Text(
      t.toUpperCase(),
      style: TextStyle(
        color: GE.sub,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      ),
    ),
  );
}

// ────────────────────────────────────────────────────────────────────────
/// Упрощённая карточка поста для профиля — текст, медиа, репост-метка, статы.
/// Для полной интерактивности (реакции/меню/share) — открывает пост в браузере.
class _ProfilePostTile extends StatelessWidget {
  final Map<String, dynamic> item;
  final String? myUsername;
  const _ProfilePostTile({required this.item, this.myUsername});

  @override
  Widget build(BuildContext context) {
    final isRepost = item['kind'] == 'repost' || item['is_repost'] == true;
    final content = (item['content'] as String?) ?? '';
    final isNsfw = item['is_nsfw'] == true || item['is_nsfw'] == 1;
    final commentsCount = (item['comments_count'] as num?)?.toInt() ?? 0;
    final reactions = item['reactions'];
    int reactionsTotal = 0;
    if (reactions is Map) {
      final total = reactions['total'];
      if (total is num) {
        reactionsTotal = total.toInt();
      } else {
        for (final v in reactions.values) {
          if (v is num) reactionsTotal += v.toInt();
        }
      }
    }
    final mediaList = (item['media'] is List)
        ? item['media'] as List
        : const [];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: GlassCard(
        lite: true,
        isListSection: true,
        padding: const EdgeInsets.all(12),
        onTap: () => PublicPageLink.open('${GE.baseUrl}/p/${item['id']}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isRepost)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.repeat, size: 12, color: GE.sub),
                    const SizedBox(width: 4),
                    Text(
                      'репост',
                      style: TextStyle(
                        color: GE.sub,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                if (isNsfw)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: GE.red.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      '18+',
                      style: TextStyle(
                        color: GE.red,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                const Spacer(),
                Text(
                  _ago(item['created_at']),
                  style: TextStyle(color: GE.sub, fontSize: 11),
                ),
              ],
            ),
            if (isNsfw) ...[
              const SizedBox(height: 8),
              Container(
                height: 90,
                decoration: BoxDecoration(
                  color: GE.scrimSoft,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: GE.red.withValues(alpha: 0.3)),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.eye_slash, color: GE.red, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      '18+ — открыть в браузере',
                      style: TextStyle(color: GE.text, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ] else ...[
              if (content.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  content,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: GE.text, fontSize: 14, height: 1.35),
                ),
              ],
              if (mediaList.isNotEmpty) ...[
                const SizedBox(height: 6),
                _MediaPreview(media: mediaList),
              ],
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (reactionsTotal > 0) ...[
                  Icon(CupertinoIcons.heart_fill, size: 12, color: GE.red),
                  const SizedBox(width: 3),
                  Text(
                    '$reactionsTotal',
                    style: TextStyle(color: GE.sub, fontSize: 11),
                  ),
                  const SizedBox(width: 12),
                ],
                if (commentsCount > 0) ...[
                  Icon(CupertinoIcons.chat_bubble, size: 12, color: GE.sub),
                  const SizedBox(width: 3),
                  Text(
                    '$commentsCount',
                    style: TextStyle(color: GE.sub, fontSize: 11),
                  ),
                ],
                const Spacer(),
                Icon(
                  CupertinoIcons.arrow_up_right_square,
                  size: 12,
                  color: GE.sub,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _ago(dynamic at) {
    if (at == null) return '';
    try {
      DateTime dt;
      if (at is int) {
        dt = DateTime.fromMillisecondsSinceEpoch(at * 1000);
      } else {
        dt = DateTime.parse(at.toString());
      }
      if (!dt.isUtc) dt = dt.toUtc();
      final s = DateTime.now().toUtc().difference(dt).inSeconds;
      if (s < 60) return 'только что';
      if (s < 3600) return '${s ~/ 60} мин';
      if (s < 86400) return '${s ~/ 3600} ч';
      if (s < 7 * 86400) return '${s ~/ 86400} д';
      return '${dt.toLocal().day}.${dt.toLocal().month.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }
}

class _ProfileMusicDraft {
  final dynamic audio;
  final dynamic cover;
  final bool coverChanged;
  final String name;
  final String artist;
  final String album;

  const _ProfileMusicDraft({
    required this.audio,
    required this.cover,
    required this.coverChanged,
    required this.name,
    required this.artist,
    required this.album,
  });
}

Future<_ProfileMusicDraft?> _showProfileMusicEditor(
  BuildContext context, {
  Map<String, dynamic>? initial,
}) async {
  final name = TextEditingController(text: initial?['name'] as String? ?? '');
  final artist = TextEditingController(
    text: initial?['artist'] as String? ?? '',
  );
  final album = TextEditingController(text: initial?['album'] as String? ?? '');
  dynamic audio;
  dynamic cover;
  var coverChanged = false;

  try {
    return await showModalBottomSheet<_ProfileMusicDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: GE.surface,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final currentCover = initial?['cover_url'] as String?;
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                12,
                20,
                20 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: GE.sub.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Музыка профиля',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Карточка появится сразу под шапкой профиля. Воспроизведение начинается только по нажатию.',
                      style: TextStyle(color: GE.sub, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await fs.openFile(
                          acceptedTypeGroups: [
                            fs.XTypeGroup(
                              label: 'Аудио',
                              extensions: ['mp3', 'm4a', 'wav', 'ogg'],
                            ),
                          ],
                        );
                        if (picked == null) return;
                        setSheetState(() {
                          audio = picked;
                          if (name.text.trim().isEmpty) {
                            name.text = picked.name.replaceFirst(
                              RegExp(r'\.[^.]+$'),
                              '',
                            );
                          }
                        });
                      },
                      icon: const Icon(CupertinoIcons.music_note_2),
                      label: Text(
                        audio == null
                            ? (initial == null
                                  ? 'Выбрать аудиофайл'
                                  : 'Заменить аудиофайл')
                            : 'Файл: ${audio.name}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: name,
                      textInputAction: TextInputAction.next,
                      maxLength: 120,
                      decoration: const InputDecoration(labelText: 'Название'),
                    ),
                    TextField(
                      controller: artist,
                      textInputAction: TextInputAction.next,
                      maxLength: 120,
                      decoration: const InputDecoration(
                        labelText: 'Исполнитель',
                      ),
                    ),
                    TextField(
                      controller: album,
                      maxLength: 120,
                      decoration: const InputDecoration(labelText: 'Альбом'),
                    ),
                    const SizedBox(height: 4),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await ImagePicker().pickImage(
                          source: ImageSource.gallery,
                          maxWidth: 1200,
                          maxHeight: 1200,
                          imageQuality: 86,
                        );
                        if (picked == null) return;
                        setSheetState(() {
                          cover = picked;
                          coverChanged = true;
                        });
                      },
                      icon: const Icon(CupertinoIcons.photo),
                      label: Text(
                        cover != null
                            ? 'Обложка: ${cover.name}'
                            : currentCover != null && !coverChanged
                            ? 'Обложка сохранена'
                            : 'Добавить обложку',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (currentCover != null && !coverChanged)
                      TextButton.icon(
                        onPressed: () => setSheetState(() {
                          cover = null;
                          coverChanged = true;
                        }),
                        icon: const Icon(CupertinoIcons.trash, size: 17),
                        label: const Text('Убрать текущую обложку'),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          child: const Text('Отмена'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: audio == null && initial == null
                              ? null
                              : () => Navigator.pop(
                                  sheetContext,
                                  _ProfileMusicDraft(
                                    audio: audio,
                                    cover: cover,
                                    coverChanged: coverChanged,
                                    name: name.text.trim(),
                                    artist: artist.text.trim(),
                                    album: album.text.trim(),
                                  ),
                                ),
                          child: const Text('Сохранить'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  } finally {
    name.dispose();
    artist.dispose();
    album.dispose();
  }
}

class _DailyThoughtBubble extends StatelessWidget {
  final String text;
  final String? mood;
  final bool empty;
  final VoidCallback? onTap;
  final int likes;
  final bool liked;
  final bool likeBusy;
  final VoidCallback? onLike;
  final VoidCallback? onShare;

  const _DailyThoughtBubble({
    required this.text,
    required this.mood,
    this.empty = false,
    this.onTap,
    this.likes = 0,
    this.liked = false,
    this.likeBusy = false,
    this.onLike,
    this.onShare,
  });

  String get _emoji => switch (mood) {
    'fire' => '🔥',
    'love' => '❤️',
    'tired' => '😴',
    'chill' => '🧊',
    'surprised' => '😮',
    _ => '🙂',
  };

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      lite: true,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      onTap: onTap,
      child: Row(
        children: [
          Text(_emoji, style: const TextStyle(fontSize: 19)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: empty ? GE.sub : GE.text,
                fontSize: 13.5,
                fontStyle: empty ? FontStyle.italic : FontStyle.normal,
                height: 1.25,
              ),
            ),
          ),
          if (!empty && onLike != null)
            GestureDetector(
              onTap: likeBusy ? null : onLike,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      liked ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
                      color: liked ? GE.primary : GE.sub,
                      size: 16,
                    ),
                    if (likes > 0) ...[
                      const SizedBox(width: 4),
                      Text(
                        '$likes',
                        style: TextStyle(color: GE.sub, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          if (!empty && onShare != null)
            GestureDetector(
              onTap: onShare,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(
                  CupertinoIcons.arrowshape_turn_up_right,
                  color: GE.sub,
                  size: 16,
                ),
              ),
            ),
          if (onTap != null) ...[
            const SizedBox(width: 6),
            Icon(CupertinoIcons.pencil, color: GE.sub, size: 16),
          ],
        ],
      ),
    );
  }
}

class _MediaPreview extends StatelessWidget {
  final List media;
  const _MediaPreview({required this.media});

  String _abs(String u) => u.startsWith('http') ? u : '${GE.baseUrl}$u';

  @override
  Widget build(BuildContext context) {
    final imgs = media
        .whereType<Map>()
        .where((m) => m['type'] == 'image' && m['url'] is String)
        .map((m) => m['url'] as String)
        .toList();
    if (imgs.isEmpty) {
      // Видео/аудио — иконка-заглушка
      return Container(
        height: 70,
        decoration: BoxDecoration(
          color: GE.glassFill,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Icon(CupertinoIcons.play_circle, color: GE.sub, size: 28),
      );
    }
    if (imgs.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          _abs(imgs[0]),
          height: 200,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(
            height: 80,
            color: GE.glassFill,
            alignment: Alignment.center,
            child: Icon(Icons.broken_image, color: GE.sub),
          ),
        ),
      );
    }
    // Grid 2-3+
    final visible = imgs.take(4).toList();
    return SizedBox(
      height: 120,
      child: Row(
        children: [
          for (var i = 0; i < visible.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  _abs(visible[i]),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(color: GE.glassFill),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
