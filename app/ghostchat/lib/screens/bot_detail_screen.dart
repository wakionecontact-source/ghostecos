// Управление одним ботом: переименование + перевыпуск токена. Юзернейм
// неизменяем (как в Telegram) — ничего на него по id не завязано, поэтому
// не чиним кэши/ссылки при regenerate.
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../widgets/toast_overlay.dart';
import '../widgets/bot_token_sheet.dart';
import '../widgets/avatar.dart';
import '../widgets/bot_badge.dart';
import '../widgets/profile_banner.dart';
import '../services/api_client.dart';
import '../services/chat_repo.dart';
import '../services/profile_cache.dart';
import 'chat_screen.dart';

class BotDetailScreen extends StatefulWidget {
  final int botId;
  final String username;
  final String displayName;
  final String? avatarUrl;
  const BotDetailScreen({
    super.key,
    required this.botId,
    required this.username,
    required this.displayName,
    this.avatarUrl,
  });

  @override
  State<BotDetailScreen> createState() => _BotDetailScreenState();
}

class _BotDetailScreenState extends State<BotDetailScreen> {
  final _imagePicker = ImagePicker();
  late final _nameCtrl = TextEditingController(text: widget.displayName);
  bool _busySave = false;
  bool _busyRegen = false;
  bool _busyAvatar = false;
  bool _busyBanner = false;
  String? _avatarUrl;
  String? _botStatus;
  ProfileBannerConfig? _bannerConfig;

  @override
  void initState() {
    super.initState();
    _nameCtrl.addListener(_refreshPreview);
    _avatarUrl = widget.avatarUrl;
    _loadProfile();
  }

  void _refreshPreview() {
    if (mounted) setState(() {});
  }

  Future<void> _loadProfile() async {
    try {
      final raw = await ApiClient().socGet('/prof/${widget.username}');
      if (raw is! Map) return;
      final profile = Map<String, dynamic>.from(raw);
      if (mounted) {
        setState(() {
          _avatarUrl = profile['avatar_url'] as String? ?? _avatarUrl;
          _bannerConfig = ProfileBannerConfig.fromDynamic(profile['banner']);
          _botStatus = profile['bot_status'] as String?;
        });
      }
      await ProfileCache.instance.setProfile(widget.username, profile);
      if (await ChatRepo.instance.isPeerBot(widget.username)) {
        await ChatRepo.instance.refreshPeerBotStatus(widget.username);
      }
    } catch (_) {
      // The list entry remains a useful offline fallback for this editor.
    }
  }

  Future<void> _updateCachedProfile(Map<String, dynamic> updates) async {
    final cached =
        ProfileCache.instance.getProfileSync(widget.username) ??
        await ProfileCache.instance.getProfile(widget.username);
    if (cached == null) return;
    await ProfileCache.instance.setProfile(widget.username, {
      ...cached,
      ...updates,
    });
  }

  @override
  void dispose() {
    _nameCtrl.removeListener(_refreshPreview);
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() => _busySave = true);
    try {
      await ApiClient().botsPost('/${widget.botId}/update', {
        'display_name': name,
      });
      await _updateCachedProfile({'display_name': name});
      if (!mounted) return;
      toast.show('Сохранено');
    } catch (e) {
      if (!mounted) return;
      toast.show('Не получилось: $e');
    } finally {
      if (mounted) setState(() => _busySave = false);
    }
  }

  Future<void> _pickAvatar() async {
    if (_busyAvatar) return;
    final picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 88,
    );
    if (picked == null || !mounted) return;
    setState(() => _busyAvatar = true);
    try {
      final bytes = await picked.readAsBytes();
      final extension = picked.name.split('.').last.toLowerCase();
      final mime = switch (extension) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        _ => 'image/jpeg',
      };
      final url = await ApiClient().uploadBotAvatar(
        botId: widget.botId,
        bytes: bytes,
        filename: picked.name.isEmpty ? 'bot-avatar.jpg' : picked.name,
        mime: mime,
      );
      if (!mounted) return;
      setState(() {
        _avatarUrl = url;
        _busyAvatar = false;
      });
      await ChatRepo.instance.cachePeerAvatar(widget.username, url);
      await _updateCachedProfile({'avatar_url': url});
      toast.show('Аватар бота обновлён');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busyAvatar = false);
      toast.show('Не удалось загрузить аватар: $error');
    }
  }

  Future<void> _removeAvatar() async {
    if (_busyAvatar || _avatarUrl == null) return;
    setState(() => _busyAvatar = true);
    try {
      await ApiClient().deleteBotAvatar(widget.botId);
      if (!mounted) return;
      setState(() {
        _avatarUrl = null;
        _busyAvatar = false;
      });
      await ChatRepo.instance.cachePeerAvatar(widget.username, null);
      await _updateCachedProfile({'avatar_url': null});
      toast.show('Аватар удалён');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busyAvatar = false);
      toast.show('Не удалось удалить аватар: $error');
    }
  }

  Future<void> _editBanner() async {
    if (_busyBanner) return;
    final result = await showProfileBannerEditor(
      context,
      initial: _bannerConfig,
    );
    if (result == null || !mounted) return;
    final displayName = _nameCtrl.text.trim();
    if (displayName.isEmpty) {
      toast.show('Сначала укажи отображаемое имя');
      return;
    }
    setState(() => _busyBanner = true);
    try {
      await ApiClient().botsPost('/${widget.botId}/update', {
        'display_name': displayName,
        if (result.clear) 'banner_clear': true,
        if (!result.clear) 'banner': result.config!.toJson(),
      });
      final banner = result.clear ? null : result.config;
      if (!mounted) return;
      setState(() {
        _bannerConfig = banner;
        _busyBanner = false;
      });
      await _updateCachedProfile({
        'display_name': displayName,
        'banner': banner?.toJson(),
      });
      toast.show(result.clear ? 'Баннер убран' : 'Баннер сохранён');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busyBanner = false);
      toast.show('Не удалось сохранить баннер: $error');
    }
  }

  Future<void> _regenerate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Перевыпустить токен?', style: TextStyle(color: GE.text)),
        content: Text(
          'Старый токен сразу перестанет работать — бот, использующий его, '
          'перестанет отвечать, пока не обновишь токен в своём коде.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Перевыпустить', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busyRegen = true);
    try {
      final resp = await ApiClient().botsPost('/${widget.botId}/regenerate');
      final token = (resp as Map)['token'] as String?;
      if (!mounted) return;
      setState(() => _busyRegen = false);
      if (token != null) {
        await showBotTokenSheet(
          context,
          username: widget.username,
          token: token,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyRegen = false);
      toast.show('Не получилось: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(showBack: true, titleText: '@${widget.username}'),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlassCard(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Профиль бота',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 14),
                    ProfileBannerHeader(
                      banner:
                          _bannerConfig ??
                          ProfileBannerConfig.defaultGradient(),
                      avatar: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          GhostAvatar(
                            avatarUrl: _avatarUrl,
                            fallbackText: _nameCtrl.text,
                            size: 82,
                          ),
                          const Positioned(
                            left: 0,
                            bottom: 0,
                            child: BotBadge(size: 22),
                          ),
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: ValueListenableBuilder<String?>(
                              valueListenable: ChatRepo.instance.watchBotStatus(
                                widget.username,
                              ),
                              builder: (_, status, _) => Container(
                                width: 15,
                                height: 15,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: (status ?? _botStatus) == 'online'
                                      ? GE.green
                                      : GE.sub.withValues(alpha: 0.65),
                                  border: Border.all(color: GE.bg, width: 2),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      identity: Column(
                        children: [
                          Text(
                            _nameCtrl.text.trim().isEmpty
                                ? widget.displayName
                                : _nameCtrl.text.trim(),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: GE.text,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '@${widget.username}',
                            style: TextStyle(color: GE.sub),
                          ),
                          const SizedBox(height: 7),
                          ValueListenableBuilder<String?>(
                            valueListenable: ChatRepo.instance.watchBotStatus(
                              widget.username,
                            ),
                            builder: (_, status, _) =>
                                BotStatusLabel(status: status ?? _botStatus),
                          ),
                        ],
                      ),
                      avatarSize: 82,
                      bannerHeight: 88,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              GlassCard(
                padding: const EdgeInsets.fromLTRB(16, 15, 12, 8),
                isListSection: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: GE.primary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Icon(
                            CupertinoIcons.paintbrush,
                            color: GE.primary,
                            size: 19,
                          ),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Оформление профиля',
                                style: TextStyle(
                                  color: GE.text,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Аватар и баннер настраиваются здесь',
                                style: TextStyle(color: GE.sub, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      visualDensity: const VisualDensity(vertical: -2),
                      leading: Icon(
                        CupertinoIcons.person_crop_circle,
                        color: GE.primary,
                      ),
                      title: Text('Аватар', style: TextStyle(color: GE.text)),
                      subtitle: Text(
                        _avatarUrl == null ? 'Не установлен' : 'Установлен',
                        style: TextStyle(color: GE.sub, fontSize: 12),
                      ),
                      onTap: _busyAvatar ? null : _pickAvatar,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_avatarUrl != null)
                            IconButton(
                              tooltip: 'Убрать аватар',
                              onPressed: _busyAvatar ? null : _removeAvatar,
                              icon: Icon(
                                CupertinoIcons.trash,
                                color: GE.red,
                                size: 19,
                              ),
                            ),
                          IconButton(
                            tooltip: _busyAvatar
                                ? 'Загружаю…'
                                : 'Изменить аватар',
                            onPressed: _busyAvatar ? null : _pickAvatar,
                            icon: _busyAvatar
                                ? SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: GE.primary,
                                    ),
                                  )
                                : Icon(
                                    CupertinoIcons.camera,
                                    color: GE.primary,
                                    size: 20,
                                  ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: GE.border),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      visualDensity: const VisualDensity(vertical: -2),
                      leading: Icon(
                        CupertinoIcons.rectangle_on_rectangle,
                        color: GE.primary,
                      ),
                      title: Text(
                        'Баннер профиля',
                        style: TextStyle(color: GE.text),
                      ),
                      subtitle: Text(
                        _bannerConfig == null ? 'Не настроен' : 'Настроен',
                        style: TextStyle(color: GE.sub, fontSize: 12),
                      ),
                      onTap: _busyBanner ? null : _editBanner,
                      trailing: _busyBanner
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: GE.primary,
                              ),
                            )
                          : Icon(
                              CupertinoIcons.chevron_right,
                              color: GE.sub,
                              size: 17,
                            ),
                    ),
                  ],
                ),
              ),
              GlassCard(
                padding: const EdgeInsets.fromLTRB(16, 15, 14, 14),
                isListSection: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Редактирование профиля',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Изменение отображаемого имени бота',
                      style: TextStyle(color: GE.sub, fontSize: 12),
                    ),
                    const SizedBox(height: 13),
                    Text(
                      'Отображаемое имя',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _nameCtrl,
                      style: TextStyle(color: GE.text, fontSize: 14),
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: GE.glassFill,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 14,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: GE.borderStrong),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: GE.borderStrong),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: GE.primary, width: 1.5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              GlassButton(
                label: _busySave ? 'Сохраняю…' : 'Сохранить',
                icon: CupertinoIcons.checkmark_circle,
                primary: true,
                fullWidth: true,
                onTap: _busySave ? null : _save,
              ),
              const SizedBox(height: 10),
              GlassButton(
                label: 'Открыть чат с ботом',
                icon: CupertinoIcons.chat_bubble_2,
                fullWidth: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(
                      peer: widget.username,
                      isBot: true,
                      displayName: _nameCtrl.text.trim().isEmpty
                          ? widget.displayName
                          : _nameCtrl.text.trim(),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              GlassButton(
                label: 'Конструктор и запуск',
                icon: CupertinoIcons.slider_horizontal_3,
                primary: true,
                fullWidth: true,
                onTap: () => toast.show('Скоро'),
              ),
              const SizedBox(height: 28),
              Text(
                'Юзернейм @${widget.username} — постоянный, изменить нельзя (как в Telegram).',
                style: TextStyle(color: GE.sub, fontSize: 12.5, height: 1.4),
              ),
              const SizedBox(height: 20),
              GlassButton(
                label: _busyRegen ? 'Перевыпускаю…' : 'Перевыпустить токен',
                icon: CupertinoIcons.arrow_2_circlepath,
                danger: true,
                fullWidth: true,
                onTap: _busyRegen ? null : _regenerate,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
