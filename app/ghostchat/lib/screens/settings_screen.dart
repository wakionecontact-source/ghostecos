// Настройки — хаб по отделам (как в 1.19.3): список разделов, каждый открывает
// свой экран. Разделы: Внешний вид, Разрешения, Ключи (E2E), Устройства,
// LAN-чаты, Логи, О приложении. «Избранное» сюда специально не входит —
// оно теперь живёт в списке чатов (см. BookmarkStore/chat_list_screen.dart).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import '../services/public_page_link.dart';
import '../mesh_background.dart';
import '../services/chat_repo.dart';
import '../services/database_backup_service.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/profile_cache.dart';
import '../services/theme_service.dart';
import '../services/permissions_service.dart';
import '../widgets/glass.dart';
import '../widgets/avatar.dart';
import '../widgets/profile_banner.dart';
import '../widgets/skeleton.dart';
import '../widgets/toast_overlay.dart';
import '../widgets/dotted_border_box.dart';
import '../widgets/ghost_native_dialog.dart';
import 'devices_screen.dart';
import 'support_screen.dart';
import 'logs_screen.dart';
import 'lan_settings_screen.dart';
import 'storage_screen.dart';
import 'custom_theme_screen.dart';
import 'network_screen.dart';
import '../services/settings_order.dart';
import '../services/remote_settings_service.dart';
import '../services/app_security_store.dart';
import '../services/performance_service.dart';
import '../services/privacy_settings.dart';
import '../services/profile_appearance_settings.dart';
import '../services/nav_bar_settings.dart';
import '../services/chat_header_settings.dart';
import 'chat_organization_settings_screen.dart';
import '../services/app_avatar_settings.dart';
import '../services/global_audio_player.dart';
import '../core/local/lan_settings.dart';
import '../shared/utils/validators.dart';
import 'notification_settings_screen.dart';
import 'sound_settings_screen.dart';
import 'updates_settings_screen.dart';
import 'bots_screen.dart';
import 'security_screen.dart';
import '../widgets/remote_settings_panel.dart';

// ─── Хаб ────────────────────────────────────────────────────────────────────
class SettingsScreen extends StatefulWidget {
  final bool isGuest;

  /// Username used as the profile cache key. MainShell passes it for the
  /// embedded settings tab so cached data can be shown synchronously.
  final String? username;

  /// true — экран сидит как таб в bottom-nav (MainShell), не запушен через
  /// Navigator: тогда "назад" в шапке не нужен (попадёт в корневой Navigator
  /// и уведёт из MainShell вообще, а не просто закроет вкладку).
  final bool embedded;

  /// Раньше кнопка "Выйти из аккаунта" жила в мини-профиле (_ProfilePane) —
  /// после переезда таба "Профиль" на полноценный ProfileScreen (без логаута,
  /// как у чужих профилей) выход переехал сюда, как в большинстве апп.
  final VoidCallback? onLogout;

  /// Обновить identity в MainShell после смены username/display name.
  final VoidCallback? onProfileChanged;
  const SettingsScreen({
    super.key,
    this.isGuest = false,
    this.username,
    this.embedded = false,
    this.onLogout,
    this.onProfileChanged,
  });
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Режим перестановки категорий — включается долгим нажатием на ЛЮБУЮ строку
  // настроек (не только заголовок): весь список "отъезжает" вправо, слева
  // появляются ручки для драга. Выход — кнопка "Готово" в шапке.
  bool _reorderMode = false;
  final _api = ApiClient();
  Map<String, dynamic>? _ownProfile;
  bool _ownProfileLoading = false;
  bool _profileActionBusy = false;
  int _profileSyncGeneration = 0;
  final Map<String, dynamic> _pendingProfileWrites = {};
  final _settingsSearchController = TextEditingController();
  String _settingsFilter = '';

  @override
  void initState() {
    super.initState();
    _settingsSearchController.addListener(_onSettingsSearchChanged);
    AppSecurityStore.instance.revision.addListener(_onSecurityChanged);
    unawaited(ProfileAppearanceSettings.instance.load());
    unawaited(ChatHeaderSettings.instance.load());
    unawaited(AppAvatarSettings.instance.load());
    ThemeService.instance.notifier.addListener(_onTheme);
    ThemeService.instance.detailedDescriptionsNotifier.addListener(_onTheme);
    NavBarSettings.instance.backgroundNotifier.addListener(_onTheme);
    NavBarSettings.instance.labelsVisibleNotifier.addListener(_onTheme);
    NavBarSettings.instance.selectedBackgroundNotifier.addListener(_onTheme);
    NavBarSettings.instance.selectedScaleNotifier.addListener(_onTheme);
    NavBarSettings.instance.selectedFlyoutNotifier.addListener(_onTheme);
    RemoteSettingsService.instance.revisionNotifier.addListener(
      _onRemoteSettingsChanged,
    );
    unawaited(SettingsOrder.instance.load());
    if (!widget.isGuest) {
      final username = widget.username?.trim();
      if (username != null && username.isNotEmpty) {
        _ownProfile = ProfileCache.instance.getProfileSync(username);
      }
      _ownProfileLoading = _ownProfile == null;
      unawaited(_loadOwnProfile());
    }
  }

  @override
  void dispose() {
    AppSecurityStore.instance.revision.removeListener(_onSecurityChanged);
    _settingsSearchController
      ..removeListener(_onSettingsSearchChanged)
      ..dispose();
    ThemeService.instance.notifier.removeListener(_onTheme);
    ThemeService.instance.detailedDescriptionsNotifier.removeListener(_onTheme);
    NavBarSettings.instance.backgroundNotifier.removeListener(_onTheme);
    NavBarSettings.instance.labelsVisibleNotifier.removeListener(_onTheme);
    NavBarSettings.instance.selectedBackgroundNotifier.removeListener(_onTheme);
    NavBarSettings.instance.selectedScaleNotifier.removeListener(_onTheme);
    NavBarSettings.instance.selectedFlyoutNotifier.removeListener(_onTheme);
    RemoteSettingsService.instance.revisionNotifier.removeListener(
      _onRemoteSettingsChanged,
    );
    super.dispose();
  }

  void _onTheme() {
    if (mounted) setState(() {});
  }

  void _onSecurityChanged() {
    if (mounted) setState(() {});
  }

  void _onRemoteSettingsChanged() {
    if (mounted) setState(() {});
  }

  void _onSettingsSearchChanged() {
    final next = _normalizeSearch(_settingsSearchController.text);
    if (next == _settingsFilter) return;
    setState(() => _settingsFilter = next);
  }

  Future<void> _loadOwnProfile() async {
    if (widget.isGuest) return;
    final requestGeneration = _profileSyncGeneration;

    final cacheUsername = await _resolveProfileUsername();
    if (_ownProfile == null &&
        cacheUsername != null &&
        cacheUsername.isNotEmpty) {
      final cached = await ProfileCache.instance.getProfile(cacheUsername);
      if (cached != null && mounted) {
        setState(() {
          _ownProfile = cached;
          _ownProfileLoading = false;
        });
      }
    }

    try {
      final profile = await _api.getOwnProfile();
      if (!mounted || requestGeneration != _profileSyncGeneration) return;
      final ownProfile = _mergeProfileFromServer(profile)..['is_me'] = true;
      final profileId =
          ownProfile['user_id'] ?? ownProfile['id'] ?? ownProfile['uid'];
      if (profileId != null && profileId.toString().trim().isNotEmpty) {
        await AuthService.updateCachedProfile(userId: profileId.toString());
      }
      if (mounted) {
        setState(() {
          _ownProfile = ownProfile;
          _ownProfileLoading = false;
        });
      }

      final cacheKeys = <String>{};
      if (cacheUsername != null && cacheUsername.isNotEmpty) {
        cacheKeys.add(cacheUsername);
      }
      final profileUsername = (profile['username'] as String?)?.trim();
      if (profileUsername != null && profileUsername.isNotEmpty) {
        cacheKeys.add(profileUsername);
      }
      for (final key in cacheKeys) {
        try {
          await ProfileCache.instance.setProfile(key, ownProfile);
        } catch (_) {
          // A cache write must not turn a successful profile request into an
          // error visible to the user.
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _ownProfileLoading = false);
        // Keep stale cached data on screen, just like the Profile tab.
        if (_ownProfile == null) {
          toast.show('Профиль не загрузился: ${_profileError(e)}');
        }
      }
    }
  }

  Future<String?> _resolveProfileUsername() async {
    final fromWidget = widget.username?.trim();
    if (fromWidget != null && fromWidget.isNotEmpty) return fromWidget;
    final fromAuth = (await AuthService.username())?.trim();
    if (fromAuth == null || fromAuth.isEmpty) return null;
    return fromAuth;
  }

  String _profileError(Object error) {
    if (error is ApiException) return error.message;
    return error.toString();
  }

  Future<void> _applyProfileResult(
    Map<String, dynamic> result, {
    Map<String, dynamic> requestedFields = const {},
  }) async {
    final next = Map<String, dynamic>.from(_ownProfile ?? const {});
    final currentAbout = next['about'];
    next.addAll(result);
    // Старые live-инстансы могли принять PATCH с лишним полем, но вернуть
    // about=null/не вернуть его вовсе. Не затираем уже сохранённое локально
    // значение таким неполным ответом. Пустая строка — настоящий clear.
    if (result['about'] == null &&
        currentAbout is String &&
        currentAbout.trim().isNotEmpty) {
      next['about'] = currentAbout;
    }
    _pendingProfileWrites.addAll(requestedFields);
    // Успешный PATCH является источником истины для локального состояния,
    // даже если старый backend вернул неполный или устаревший ответ.
    next.addAll(requestedFields);
    next['is_me'] = true;
    if (mounted) setState(() => _ownProfile = next);
    await AuthService.updateCachedProfile(
      username: next['username'] as String?,
      displayName: next['display_name'] as String?,
    );
    final cacheKeys = <String>{};
    final widgetUsername = widget.username?.trim();
    if (widgetUsername != null && widgetUsername.isNotEmpty) {
      cacheKeys.add(widgetUsername);
    }
    final profileUsername = (next['username'] as String?)?.trim();
    if (profileUsername != null && profileUsername.isNotEmpty) {
      cacheKeys.add(profileUsername);
    }
    for (final key in cacheKeys) {
      try {
        await ProfileCache.instance.setProfile(key, next);
      } catch (_) {}
    }
    widget.onProfileChanged?.call();
  }

  Map<String, dynamic> _mergeProfileFromServer(Map<String, dynamic> profile) {
    final currentAbout = _ownProfile?['about'];
    final next = Map<String, dynamic>.from(profile);
    for (final entry in _pendingProfileWrites.entries.toList()) {
      if (next.containsKey(entry.key) && next[entry.key] == entry.value) {
        _pendingProfileWrites.remove(entry.key);
      } else {
        next[entry.key] = entry.value;
      }
    }
    // Пока backend обновляется, GET /me на старом инстансе может отдавать
    // about=null или вообще без ключа. Такой ответ не является подтверждением
    // удаления, поэтому сохраняем известное значение из RAM/дискового кэша.
    if (next['about'] == null &&
        currentAbout is String &&
        currentAbout.trim().isNotEmpty) {
      next['about'] = currentAbout;
    }
    return next;
  }

  Future<String?> _askTextValue({
    required String title,
    required String hint,
    required String initial,
    required IconData icon,
    bool obscure = false,
    bool autocorrect = true,
    TextInputType? keyboardType,
    int maxLines = 1,
    int? maxLength,
  }) async {
    return showGlassSheet<String>(
      context,
      child: _ProfileTextValueSheet(
        title: title,
        hint: hint,
        initial: initial,
        icon: icon,
        obscure: obscure,
        autocorrect: autocorrect,
        keyboardType: keyboardType,
        maxLines: maxLines,
        maxLength: maxLength,
      ),
    );
  }

  Future<bool> _confirmProfileAction({
    required String title,
    required String message,
  }) async {
    final result = await showGlassSheet<bool>(
      context,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: GE.text,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Text(message, style: TextStyle(color: GE.sub, fontSize: 13)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: GlassButton(
                    label: 'Нет',
                    onTap: () => Navigator.of(context).pop(false),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GlassButton(
                    label: 'Да',
                    primary: true,
                    onTap: () => Navigator.of(context).pop(true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    return result == true;
  }

  Future<void> _editDisplayName() async {
    if (_profileActionBusy || _ownProfile == null) return;
    final current = _ownProfile!['display_name'] as String? ?? '';
    final value = await _askTextValue(
      title: 'Изменить имя',
      hint: 'Имя',
      initial: current,
      icon: CupertinoIcons.person,
      maxLength: 100,
    );
    if (value == null || !mounted) return;
    final error = Validators.name(value);
    if (error != null) {
      toast.show(error);
      return;
    }
    await _saveProfileFields(displayName: value.trim());
  }

  Future<void> _editAbout() async {
    if (_profileActionBusy || _ownProfile == null) return;
    final current = _ownProfile!['about'] as String? ?? '';
    final value = await _askTextValue(
      title: 'Изменить информацию о себе',
      hint: 'О себе',
      initial: current,
      icon: CupertinoIcons.info_circle,
      maxLines: 3,
      maxLength: 256,
      keyboardType: TextInputType.multiline,
    );
    if (value == null || !mounted) return;
    await _saveProfileFields(about: value.trim());
  }

  Future<void> _editUsername() async {
    if (_profileActionBusy || _ownProfile == null) return;
    final current = _ownProfile!['username'] as String? ?? '';
    final raw = await _askTextValue(
      title: 'Изменить имя пользователя',
      hint: 'username',
      initial: current,
      icon: CupertinoIcons.at,
      autocorrect: false,
      keyboardType: TextInputType.visiblePassword,
      maxLength: 64,
    );
    if (raw == null || !mounted) return;
    final username = Validators.normalizeUsername(raw);
    final error = Validators.username(username);
    if (error != null) {
      toast.show(error);
      return;
    }
    if (username == current) return;

    final oldPassword = await _askTextValue(
      title: 'Подтвердите смену username',
      hint: 'Текущий пароль',
      initial: '',
      icon: CupertinoIcons.lock,
      obscure: true,
      autocorrect: false,
      keyboardType: TextInputType.visiblePassword,
      maxLength: 150,
    );
    if (oldPassword == null || oldPassword.isEmpty || !mounted) return;
    await _saveProfileFields(username: username, oldPassword: oldPassword);
  }

  Future<void> _saveProfileFields({
    String? displayName,
    String? about,
    String? username,
    String? oldPassword,
  }) async {
    if (_profileActionBusy) return;
    final requestedFields = <String, dynamic>{};
    if (displayName != null) requestedFields['display_name'] = displayName;
    if (about != null) requestedFields['about'] = about;
    if (username != null) requestedFields['username'] = username;
    _profileSyncGeneration++;
    setState(() => _profileActionBusy = true);
    try {
      final result = await _api.updateOwnProfile(
        displayName: displayName,
        about: about,
        username: username,
        oldPassword: oldPassword,
      );
      // Инвалидируем уже запущенный GET /me: он мог начаться до PATCH и
      // вернуть старое значение после успешного сохранения.
      _profileSyncGeneration++;
      await _applyProfileResult(result, requestedFields: requestedFields);
      if (mounted) toast.show('Профиль обновлён');
    } catch (e) {
      if (mounted)
        toast.show('Не удалось обновить профиль: ${_profileError(e)}');
    } finally {
      if (mounted) setState(() => _profileActionBusy = false);
    }
  }

  Future<void> _changePasswordFlow() async {
    if (_profileActionBusy || widget.isGuest) return;
    setState(() => _profileActionBusy = true);
    String? oldPassword;
    try {
      final confirmed = await _confirmProfileAction(
        title: 'Сменить пароль?',
        message:
            'Потребуется ввести текущий пароль. После 5 неверных попыток приложение выйдет из аккаунта.',
      );
      if (!confirmed || !mounted) return;

      for (var attempt = 1; attempt <= 5; attempt++) {
        final candidate = await _askTextValue(
          title: 'Текущий пароль',
          hint: 'Введите текущий пароль',
          initial: '',
          icon: CupertinoIcons.lock,
          obscure: true,
          autocorrect: false,
          keyboardType: TextInputType.visiblePassword,
          maxLength: 150,
        );
        if (candidate == null || !mounted) return;
        try {
          await _api.verifyOwnPassword(candidate);
          // Сохраняем только в RAM до завершения финального запроса; в
          // SharedPreferences/SecureStorage пароль не попадает.
          oldPassword = candidate;
          break;
        } catch (e) {
          if (attempt == 5) {
            toast.show('5 попыток исчерпано. Выполняется выход из аккаунта.');
            if (widget.onLogout != null) {
              widget.onLogout!.call();
            } else {
              await AuthService.logout();
            }
            return;
          }
          toast.show(
            'Неверный текущий пароль. Осталось попыток: ${5 - attempt}',
          );
        }
      }

      if (oldPassword == null || !mounted) return;
      final newPassword = await _askTextValue(
        title: 'Новый пароль',
        hint: 'Введите новый пароль',
        initial: '',
        icon: CupertinoIcons.lock_fill,
        obscure: true,
        autocorrect: false,
        keyboardType: TextInputType.visiblePassword,
        maxLength: 150,
      );
      if (newPassword == null || !mounted) return;
      final validationError = Validators.password(newPassword);
      if (validationError != null) {
        toast.show(validationError);
        return;
      }
      if (newPassword == oldPassword) {
        toast.show('Новый пароль не должен совпадать с текущим');
        return;
      }

      final finalConfirmation = await _confirmProfileAction(
        title: 'Подтвердить смену пароля?',
        message: 'После подтверждения потребуется войти с новым паролем.',
      );
      if (!finalConfirmation || !mounted) return;

      final result = await _api.updateOwnProfile(
        oldPassword: oldPassword,
        newPassword: newPassword,
      );
      final newToken = result['token'] as String?;
      if (newToken != null) await AuthService.replaceToken(newToken);
      await _applyProfileResult(result);
      if (mounted) toast.show('Пароль изменён');
    } catch (e) {
      if (mounted) toast.show('Не удалось сменить пароль: ${_profileError(e)}');
    } finally {
      // Убираем ссылку на старый пароль сразу после завершения сценария.
      oldPassword = null;
      if (mounted) setState(() => _profileActionBusy = false);
    }
  }

  Future<void> _pickAndUploadAvatar() async {
    if (_profileActionBusy || widget.isGuest) return;
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 90,
    );
    if (picked == null || !mounted) return;
    setState(() => _profileActionBusy = true);
    try {
      final bytes = await picked.readAsBytes();
      final url = await _api.uploadOwnAvatar(
        bytes: bytes,
        filename: picked.name,
      );
      if (!mounted) return;
      // Сразу сохраняем выбранные байты и новую ссылку: вкладка профиля
      // покажет их из памяти, пока фоновый GET проверяет серверную версию.
      await AvatarCache.instance.save(AvatarCache.resolveUrl(url)!, bytes);
      await _applyProfileResult({'avatar_url': url});
      toast.show('Аватарка обновлена');
    } catch (e) {
      if (mounted)
        toast.show('Не удалось загрузить аватарку: ${_profileError(e)}');
    } finally {
      if (mounted) setState(() => _profileActionBusy = false);
    }
  }

  Future<void> _editBanner() async {
    if (_profileActionBusy || widget.isGuest || _ownProfile == null) return;
    final result = await showProfileBannerEditor(
      context,
      initial: ProfileBannerConfig.fromDynamic(_ownProfile?['banner']),
    );
    if (result == null || !mounted) return;

    final fallback = ProfileBannerConfig.defaultGradient().toJson();
    final requestedFields = <String, dynamic>{
      'banner': result.clear ? fallback : result.config!.toJson(),
    };
    _profileSyncGeneration++;
    setState(() => _profileActionBusy = true);
    try {
      final response = await _api.updateOwnProfile(
        banner: result.clear ? null : result.config!.toJson(),
        clearBanner: result.clear,
      );
      _profileSyncGeneration++;
      await _applyProfileResult(response, requestedFields: requestedFields);
      if (mounted) {
        toast.show(
          result.clear ? 'Баннер сброшен к умолчанию' : 'Баннер сохранён',
        );
      }
    } catch (e) {
      if (mounted) {
        toast.show('Не удалось сохранить баннер: ${_profileError(e)}');
      }
    } finally {
      if (mounted) setState(() => _profileActionBusy = false);
    }
  }

  void _enterReorderMode() {
    if (_reorderMode) return;
    HapticFeedback.mediumImpact();
    setState(() => _reorderMode = true);
  }

  void _exitReorderMode() {
    HapticFeedback.selectionClick();
    setState(() => _reorderMode = false);
  }

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  /// Каждая категория — заголовок (с зажатием на переупорядочивание) + карточка.
  /// Ключи — см. settings_order.dart (settingsCategoryLabels).
  Map<String, Widget> _categoryBlocks(BuildContext context) => {
    'account': Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _categoryHeader(context, 'account'),
        GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              if (!widget.isGuest)
                _row(
                  Icons.smart_toy_rounded,
                  'Мои боты',
                  'Создание и управление ботами',
                  () => _open(const BotsScreen()),
                  searchTerms: 'боты бот создание управление',
                ),
              _row(
                Icons.devices_other_outlined,
                'Устройства',
                'Сессии и доверенные устройства',
                () => _open(const DevicesScreen()),
                disabled: widget.isGuest,
                searchTerms: 'устройства сессии доверенные',
              ),
              _row(
                Icons.vpn_key_outlined,
                'Ключи шифрования',
                'Копия ключа, seed-фраза, перезалить ключ',
                () => _open(const _KeysScreen()),
                searchTerms: 'ключи шифрование seed фраза перезалить',
                last: true,
              ),
            ],
          ),
        ),
      ],
    ),
    'appearance': Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _categoryHeader(context, 'appearance'),
        GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _row(
            Icons.palette_outlined,
            'Внешний вид',
            'Тема оформления',
            () => _open(
              _AppearanceScreen(
                initialPanel: _appearancePanelForQuery(_settingsFilter),
              ),
            ),
            searchTerms:
                'цвет фон стекло liquid glass матовый эффект анимация плеер интерфейс профиль баннер аватар музыка нижний бар навигация подписи текст под иконками выбранная категория выделение увеличить вылетает влево другое заголовок чаты имя юзернейм ghostchat',
            last: true,
          ),
        ),
        const RemoteSettingsPanel(category: 'appearance'),
      ],
    ),
    'security': Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _categoryHeader(context, 'security'),
        GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              _row(
                CupertinoIcons.lock_shield,
                'Приватность',
                'Видимость в сети и статус прочтения',
                () => _open(const _PrivacyScreen()),
                searchTerms:
                    'приватность безопасность видимость сеть статус прочтения звонки',
                last: false,
              ),
              _row(
                CupertinoIcons.lock_shield_fill,
                'Безопасность приложения',
                'Блок-код и скрытые безопасные среды',
                () => _open(const AppSecurityScreen()),
                searchTerms:
                    'безопасность блок код пароль безопасная среда скрытые группы',
                last: true,
              ),
            ],
          ),
        ),
      ],
    ),
    'beta': Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _categoryHeader(context, 'beta'),
        GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _row(
            CupertinoIcons.sparkles,
            'Бета-функции',
            'Экспериментальные возможности приложения',
            () => _open(_BetaFeaturesScreen(initialQuery: _settingsFilter)),
            searchTerms:
                'бета функции экспериментальные возможности аватар аватарка аватар приложения иконка приложения оригинальная цветовые варианты',
            last: true,
          ),
        ),
        const RemoteSettingsPanel(category: 'network'),
      ],
    ),
    'privacy': Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _categoryHeader(context, 'privacy'),
        GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              _row(
                Icons.battery_saver,
                'Энергосбережение',
                'FPS фона, анимации, качество интерфейса',
                () => _open(const _PowerSavingScreen()),
                searchTerms: 'энергосбережение fps фон анимации качество заряд',
              ),
              _row(
                CupertinoIcons.checkmark_shield,
                'Разрешения',
                'Доступ к камере, микрофону, уведомлениям',
                () => _open(const _PermissionsManageScreen()),
                searchTerms: 'разрешения камера микрофон уведомления доступ',
              ),
              _row(
                CupertinoIcons.antenna_radiowaves_left_right,
                'LAN-чаты',
                'Приём запросов, приоритет, блокировки',
                () => _open(const LanSettingsScreen()),
                searchTerms: 'lan чаты приём запросы приоритет блокировки',
              ),
              _row(
                CupertinoIcons.bell,
                'Уведомления',
                'Push, исключения, внутренние тосты',
                () => _open(const NotificationSettingsScreen()),
                searchTerms: 'уведомления push исключения тосты',
              ),
              _row(
                CupertinoIcons.arrow_down_circle,
                'Обновления',
                'Проверка версии и установка новой сборки',
                () => _open(const UpdatesSettingsScreen()),
                searchTerms: 'обновления версия установка сборка',
                last: true,
              ),
            ],
          ),
        ),
      ],
    ),
    'data': Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _categoryHeader(context, 'data'),
        GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              _row(
                CupertinoIcons.chart_pie,
                'Хранилище',
                'Фото, видео, голосовые, файлы',
                () => _open(const StorageScreen()),
                searchTerms: 'хранилище фото видео голосовые файлы медиа',
              ),
              _row(
                CupertinoIcons.folder,
                'Группы и архив чатов',
                'Вкладки, вложенные группы и срок хранения архива',
                () => _open(const ChatOrganizationSettingsScreen()),
                searchTerms:
                    'группы чатов папки архив срок хранения удалить локально',
              ),
              _row(
                CupertinoIcons.archivebox,
                'Резервное копирование',
                'Зашифрованная копия локальной истории',
                () => _openBackupMenu(context),
                searchTerms:
                    'резервное копирование зашифрованная копия история',
                last: true,
              ),
            ],
          ),
        ),
      ],
    ),
    'soon': Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _categoryHeader(context, 'soon'),
        GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              _row(
                CupertinoIcons.arrow_up_arrow_down,
                'Импорт и экспорт чатов',
                'Перенос чатов в файл и из файла — скоро',
                null,
                searchTerms: 'импорт экспорт чатов файл скоро',
                last: true,
              ),
            ],
          ),
        ),
      ],
    ),
    'network': Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _categoryHeader(context, 'network'),
        GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _row(
            CupertinoIcons.wifi,
            'Сеть',
            'Куда идут запросы, прокси',
            () => _open(const NetworkScreen()),
            searchTerms: 'сеть api прокси lan соединение запросы',
            last: true,
          ),
        ),
      ],
    ),
    'dev': Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _categoryHeader(context, 'dev'),
        GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              _row(
                Icons.terminal_rounded,
                'Логи',
                'Внутренний журнал (LAN/BLE/Wi-Fi Direct)',
                () => _open(const LogsScreen()),
                searchTerms: 'логи разработка журнал lan ble wi-fi direct',
                last: true,
              ),
            ],
          ),
        ),
      ],
    ),
    'other': Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _categoryHeader(context, 'other'),
        GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _row(
            CupertinoIcons.info_circle,
            'О приложении',
            'Версия, помощь',
            () => _open(const _AboutScreen()),
            searchTerms: 'о приложении версия помощь',
            last: true,
          ),
        ),
      ],
    ),
  };

  Widget _categoryHeader(BuildContext context, String key) => _sectionTitle(
    settingsCategoryLabels[key] ?? key,
    beta: settingsBetaCategoryKeys.contains(key),
  );

  static const _settingsSearchTerms = <String, String>{
    'appearance':
        'внешний вид тема оформление стиль цвет фон стекло liquid glass матовый эффект анимация плеер интерфейс профиль баннер аватар музыка нижний бар навигация подписи текст под иконками выбранная категория выделение увеличить вылетает влево другое заголовок чаты имя юзернейм ghostchat',
    'privacy':
        'энергосбережение разрешения lan чаты уведомления обновления push камера микрофон',
    'security':
        'приватность безопасность видимость сеть статус прочтения звонки',
    'account':
        'мои боты устройства ключи шифрования сессии доверенные устройства',
    'data': 'хранилище резервное копирование фото видео голосовые файлы медиа',
    'network': 'сеть api прокси lan соединение запросы',
    'dev': 'логи разработка журнал внутренний журнал',
    'other': 'о приложении версия помощь',
    'soon': 'импорт и экспорт чатов скоро',
    'beta':
        'бета-функции экспериментальные возможности звук звуки сигнал аватар аватарка аватар приложения иконка приложения оригинальная цветовые варианты',
  };

  bool _matchesSettingsCategory(String key) {
    if (AppSecurityStore.instance.isInSafeMode &&
        (key == 'security' || key == 'dev')) {
      return false;
    }
    if (_settingsFilter.isEmpty) return true;
    final terms = _normalizeSearch(_settingsSearchTerms[key] ?? '');
    // Search the actual setting entries represented by the section, not the
    // section name alone. Individual rows apply the same filter below.
    final remoteTerms = _normalizeSearch(
      RemoteSettingsService.instance.searchableTextForCategory(key),
    );
    return terms.contains(_settingsFilter) ||
        remoteTerms.contains(_settingsFilter);
  }

  bool _matchesSettingEntry(
    String title,
    String sub, {
    String searchTerms = '',
  }) {
    if (_settingsFilter.isEmpty) return true;
    return _normalizeSearch(
      '$title $sub $searchTerms',
    ).contains(_settingsFilter);
  }

  static String _normalizeSearch(String value) =>
      value.trim().toLowerCase().replaceAll('ё', 'е');

  String? _appearancePanelForQuery(String query) {
    final q = _normalizeSearch(query);
    if (q.isEmpty) return null;
    if (q.contains('баннер') ||
        q.contains('аватар') ||
        q.contains('профиль') ||
        q.contains('музык')) {
      return 'profile';
    }
    if (q.contains('нижн') ||
        q.contains('навигац') ||
        q.contains('подпис') ||
        q.contains('икон') ||
        q.contains('выделен') ||
        q.contains('вылет')) {
      return 'navbar';
    }
    if (q.contains('заголов') ||
        q.contains('ghostchat') ||
        q.contains('юзернейм') ||
        q.contains('имя') ||
        q.contains('назван') ||
        q == 'чаты' ||
        q.startsWith('чаты ')) {
      return 'other';
    }
    if (q.contains('проигрыв') || q.contains('плеер') || q.contains('аудио')) {
      return 'player';
    }
    if (q.contains('анимирован') || q.contains('mesh')) return 'background';
    if (q.contains('сообщен') || q.contains('врем')) return 'messages';
    if (q.contains('производ') || q.contains('fps')) return 'performance';
    return 'style';
  }

  Widget _settingsSearchField() => DecoratedBox(
    decoration: BoxDecoration(
      color: GE.glassFill.withValues(alpha: 0.66),
      borderRadius: BorderRadius.circular(GE.radiusMd),
      border: Border.all(color: GE.glassBorder),
    ),
    child: TextField(
      controller: _settingsSearchController,
      textInputAction: TextInputAction.search,
      style: TextStyle(color: GE.text),
      cursorColor: GE.primary,
      decoration: InputDecoration(
        hintText: 'Найти настройку',
        hintStyle: TextStyle(color: GE.sub, fontSize: 13),
        prefixIcon: Icon(CupertinoIcons.search, color: GE.sub, size: 20),
        suffixIcon: _settingsFilter.isEmpty
            ? null
            : IconButton(
                tooltip: 'Очистить поиск',
                onPressed: _settingsSearchController.clear,
                icon: Icon(CupertinoIcons.xmark_circle_fill, color: GE.sub),
              ),
        border: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
      ),
    ),
  );

  Widget _settingsNoResults() => GlassCard(
    lite: true,
    padding: const EdgeInsets.all(22),
    child: Column(
      children: [
        Icon(CupertinoIcons.search, color: GE.primary, size: 34),
        const SizedBox(height: 10),
        Text(
          'Ничего не найдено',
          style: TextStyle(color: GE.text, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 5),
        Text(
          'Попробуй другое слово: «звук», «сеть», «ключи».',
          textAlign: TextAlign.center,
          style: TextStyle(color: GE.sub, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _accountHeader(BuildContext context) {
    if (widget.isGuest) {
      return GlassCard(
        isListSection: true,
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const GhostAvatar(avatarUrl: null, fallbackText: 'Гость', size: 68),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Гостевой режим',
                    style: TextStyle(
                      color: GE.text,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Войдите в аккаунт, чтобы менять данные профиля',
                    style: TextStyle(color: GE.sub, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (_ownProfileLoading && _ownProfile == null) {
      return GlassCard(
        isListSection: true,
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text('Загружаем профиль…', style: TextStyle(color: GE.sub)),
          ],
        ),
      );
    }

    final p = _ownProfile;
    if (p == null) {
      return GlassCard(
        isListSection: true,
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Данные аккаунта недоступны',
                style: TextStyle(color: GE.sub),
              ),
            ),
            IconButton(
              tooltip: 'Повторить',
              onPressed: _loadOwnProfile,
              icon: Icon(CupertinoIcons.refresh, color: GE.primary),
            ),
          ],
        ),
      );
    }

    final displayName = p['display_name'] as String? ?? 'Без имени';
    final username = p['username'] as String? ?? '';
    final about = (p['about'] as String? ?? '').trim();
    final banner =
        ProfileBannerConfig.fromDynamic(p['banner']) ??
        ProfileBannerConfig.defaultGradient();
    return GlassCard(
      isListSection: true,
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Мой профиль',
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Изменить баннер',
                onPressed: _profileActionBusy ? null : _editBanner,
                icon: Icon(
                  CupertinoIcons.paintbrush,
                  size: 18,
                  color: _profileActionBusy ? GE.sub : GE.text,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ValueListenableBuilder<double>(
            valueListenable: ThemeService.instance.avatarBannerBufferNotifier,
            builder: (context, _, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ProfileBannerAvatarStage(
                  banner: banner,
                  avatar: PressScale(
                    onTap: _profileActionBusy ? null : _pickAndUploadAvatar,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        GhostAvatar(
                          avatarUrl: p['avatar_url'] as String?,
                          fallbackText: displayName,
                          size: 72,
                        ),
                        Positioned(
                          right: -3,
                          bottom: -3,
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: GE.primary,
                              shape: BoxShape.circle,
                              border: Border.all(color: GE.surface, width: 2),
                            ),
                            child: const Icon(
                              CupertinoIcons.camera,
                              size: 13,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  avatarSize: 72,
                  bannerHeight: 76,
                  alignAvatarLeft: true,
                ),
                const SizedBox(height: 4),
                _profileDataRow(
                  label: 'Имя',
                  value: displayName,
                  icon: CupertinoIcons.person,
                  onEdit: _profileActionBusy ? null : _editDisplayName,
                ),
                _profileDataRow(
                  label: 'Username',
                  value: '@$username',
                  icon: CupertinoIcons.at,
                  onEdit: _profileActionBusy ? null : _editUsername,
                ),
              ],
            ),
          ),
          Divider(height: 24, color: GE.glassBorder),
          _profileDataRow(
            label: 'О себе',
            value: about.isEmpty ? 'Не указано' : about,
            icon: CupertinoIcons.info_circle,
            onEdit: _profileActionBusy ? null : _editAbout,
            maxLines: 2,
          ),
          const SizedBox(height: 6),
          _profileDataRow(
            label: 'Пароль',
            value: '••••••••',
            icon: CupertinoIcons.lock,
            onEdit: _profileActionBusy ? null : _changePasswordFlow,
          ),
          const SizedBox(height: 10),
          Divider(height: 1, color: GE.glassBorder),
          const SizedBox(height: 10),
          _profileDataRow(
            label: 'ID',
            value: _profileId(p, fallback: username),
            icon: CupertinoIcons.number,
            onEdit: null,
          ),
        ],
      ),
    );
  }

  String _profileId(Map<String, dynamic> profile, {required String fallback}) {
    for (final key in const ['id', 'user_id', 'uid']) {
      final value = profile[key]?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    // Старый сервер не всегда присылает numeric id. Не оставляем поле
    // пустым: username остаётся стабильным идентификатором аккаунта.
    return fallback;
  }

  Widget _profileDataRow({
    required String label,
    required String value,
    required IconData icon,
    required VoidCallback? onEdit,
    int maxLines = 1,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 18, color: GE.primary),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: GE.sub, fontSize: 11)),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: GE.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        if (onEdit != null) ...[
          const SizedBox(width: 6),
          AnimatedBuilder(
            animation: ThemeService.instance.listPlatesNotifier,
            builder: (context, _) => Material(
              // Сама кнопка не имеет рамки. Её заливка следует настройке
              // «Фон списков», как и внешняя карточка профиля.
              color: ThemeService.instance.listPlatesNotifier.value
                  ? GE.glassFill.withValues(alpha: 0.42)
                  : Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: IconButton(
                tooltip: 'Изменить $label',
                onPressed: onEdit,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                icon: Icon(CupertinoIcons.pencil, size: 15, color: GE.text),
              ),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = _scaffold(context);
    // embedded=true — уже внутри MainShell с одним персистентным
    // MeshBackground на все три вкладки; свой вложенный фон означал бы
    // пересоздание mesh-анимации заново при каждом возврате на вкладку.
    return widget.embedded ? scaffold : MeshBackground(child: scaffold);
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: GlassAppBar(
        showBack: !widget.embedded,
        titleText: 'Настройки',
        actions: _reorderMode
            ? [
                TextButton(
                  onPressed: _exitReorderMode,
                  child: Text(
                    'Готово',
                    style: TextStyle(
                      color: GE.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ]
            : null,
      ),
      body: ValueListenableBuilder<List<String>>(
        valueListenable: SettingsOrder.instance.orderNotifier,
        builder: (context, order, _) {
          final blocks = _categoryBlocks(context);
          final safeMode = AppSecurityStore.instance.isInSafeMode;
          final visibleOrder = order
              .where(_matchesSettingsCategory)
              .toList(growable: false);
          final reorderOrder = safeMode
              ? order.where((key) => key != 'security' && key != 'dev').toList()
              : order;
          final bottomPad = widget.embedded
              ? 120 + MediaQuery.of(context).padding.bottom
              : 12.0;
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: _reorderMode
                ? _ReorderList(
                    key: const ValueKey('reorder'),
                    order: reorderOrder,
                    blocks: blocks,
                    bottomPad: bottomPad,
                    onReorder: (oldIdx, newIdx) {
                      final movable = List<String>.of(reorderOrder);
                      final key = movable.removeAt(oldIdx);
                      movable.insert(newIdx, key);
                      if (!safeMode) {
                        SettingsOrder.instance.save(movable);
                        return;
                      }
                      var movableIndex = 0;
                      final updated = List<String>.of(order);
                      for (var index = 0; index < updated.length; index++) {
                        final current = updated[index];
                        if (current == 'security' || current == 'dev') continue;
                        updated[index] = movable[movableIndex++];
                      }
                      SettingsOrder.instance.save(updated);
                    },
                  )
                : ListView(
                    key: const ValueKey('plain'),
                    padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPad),
                    children: [
                      _accountHeader(context),
                      const SizedBox(height: 16),
                      if (!_reorderMode) ...[
                        _settingsSearchField(),
                        const SizedBox(height: 16),
                      ],
                      if (visibleOrder.isEmpty)
                        _settingsNoResults()
                      else
                        for (final key in visibleOrder)
                          blocks[key] ?? const SizedBox.shrink(),
                      if (widget.onLogout != null || !widget.isGuest) ...[
                        const SizedBox(height: 16),
                        // Стеклянная карточка вокруг кнопки выхода — раньше
                        // кнопка лежала прямо на mesh без подложки, из-за
                        // чего низ экрана выглядел "оборванным" (тот же
                        // приём, что и в нижнем навбаре MainShell).
                        GlassCard(
                          isListSection: true,
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              if (widget.onLogout != null)
                                GlassButton(
                                  label: 'Выйти из аккаунта',
                                  icon: CupertinoIcons.square_arrow_right,
                                  danger: true,
                                  fullWidth: true,
                                  onTap: () => _confirmLogout(context),
                                ),
                              if (widget.onLogout != null)
                                const SizedBox(height: 8),
                              GlassButton(
                                label: 'Удалить профиль',
                                icon: CupertinoIcons
                                    .person_crop_circle_badge_minus,
                                danger: true,
                                fullWidth: true,
                                onTap: widget.isGuest
                                    ? null
                                    : () => _confirmDeleteAccount(context),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
          );
        },
      ),
    );
  }

  void _openBackupMenu(BuildContext context) {
    showGlassSheet<void>(
      context,
      height: 270,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            _tile(
              CupertinoIcons.archivebox,
              'Создать резервную копию',
              () {
                Navigator.pop(context);
                unawaited(_exportDatabaseBackup());
              },
              sub: 'Зашифровать локальную историю в файл',
            ),
            _tile(
              CupertinoIcons.tray_arrow_down,
              'Восстановить резервную копию',
              () {
                Navigator.pop(context);
                unawaited(_restoreDatabaseBackup());
              },
              sub: 'Импортировать файл после переустановки',
            ),
            if (ThemeService.instance.showDetailedDescriptions)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
                child: Text(
                  'Восстановление заменит текущую локальную историю. Файл и пароль не отправляются на сервер.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GE.sub, fontSize: 11),
                ),
              ),
            _tile(
              CupertinoIcons.xmark,
              'Отмена',
              () => Navigator.pop(context),
              last: true,
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Future<String?> _askBackupPassword({required bool confirmation}) async {
    return _askTextValue(
      title: confirmation
          ? 'Подтвердить пароль резервной копии'
          : 'Пароль резервной копии',
      hint: 'Введите пароль',
      initial: '',
      icon: CupertinoIcons.lock,
      obscure: true,
      autocorrect: false,
      keyboardType: TextInputType.visiblePassword,
      maxLength: 512,
    );
  }

  Future<String?> _askExportBackupPassword() async {
    final password = await _askBackupPassword(confirmation: false);
    if (password == null || password.isEmpty || !mounted) return null;
    final repeated = await _askBackupPassword(confirmation: true);
    if (repeated == null || !mounted) return null;
    if (password != repeated) {
      toast.show('Пароли резервной копии не совпадают');
      return null;
    }
    return password;
  }

  Future<String?> _backupAccount() async {
    if (widget.isGuest) {
      toast.show('Резервное копирование доступно только для аккаунта');
      return null;
    }
    final fromWidget = widget.username?.trim();
    final account = fromWidget != null && fromWidget.isNotEmpty
        ? fromWidget
        : (await AuthService.username())?.trim();
    if (account == null || account.isEmpty) {
      toast.show('Не удалось определить аккаунт');
      return null;
    }
    return account;
  }

  Future<void> _exportDatabaseBackup() async {
    final account = await _backupAccount();
    if (account == null || !mounted) return;
    final password = await _askExportBackupPassword();
    if (password == null || !mounted) return;
    try {
      final saved = await DatabaseBackupService.instance.exportToFile(
        account: account,
        password: password,
      );
      if (!mounted) return;
      if (saved != null) {
        toast.show('Зашифрованная резервная копия сохранена');
      }
    } catch (_) {
      if (mounted) toast.show('Не удалось создать резервную копию');
    }
  }

  Future<void> _restoreDatabaseBackup() async {
    final account = await _backupAccount();
    if (account == null || !mounted) return;
    final password = await _askBackupPassword(confirmation: false);
    if (password == null || password.isEmpty || !mounted) return;
    final confirmed = await _confirmProfileAction(
      title: 'Заменить локальную базу?',
      message:
          'Текущая история и локальные диалоги будут заменены содержимым резервной копии. При неверном пароле база не изменится.',
    );
    if (!confirmed || !mounted) return;

    var repoStopped = false;
    try {
      // Останавливаем фоновые WS/fetch callbacks, чтобы они не писали в БД
      // одновременно с атомарной заменой файла.
      await ChatRepo.instance.dispose();
      repoStopped = true;
      final restored = await DatabaseBackupService.instance.restoreFromFile(
        account: account,
        password: password,
      );
      if (!mounted) return;
      if (restored) {
        toast.show('Резервная копия восстановлена');
      }
    } catch (_) {
      if (mounted) toast.show('Не удалось восстановить базу');
    } finally {
      if (repoStopped) {
        try {
          await ChatRepo.instance.init();
        } catch (_) {
          if (mounted) toast.show('База заменена, но чат нужно открыть заново');
        }
      }
    }
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Выйти из аккаунта?', style: TextStyle(color: GE.text)),
        content: Text(
          'Сессия на этом устройстве завершится. Войти снова — по логину/паролю или ключу.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('Выйти', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    if (ok == true) widget.onLogout?.call();
  }

  Future<void> _confirmDeleteAccount(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Удалить аккаунт?', style: TextStyle(color: GE.text)),
        content: Text(
          'Будут удалены профиль, чаты и файлы. После окончательного удаления действие нельзя отменить.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('Продолжить', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final passwordController = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Введите пароль', style: TextStyle(color: GE.text)),
        content: TextField(
          controller: passwordController,
          autofocus: true,
          obscureText: true,
          style: TextStyle(color: GE.text),
          decoration: InputDecoration(
            hintText: 'Пароль аккаунта',
            hintStyle: TextStyle(color: GE.sub),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, passwordController.text),
            child: Text('Проверить', style: TextStyle(color: GE.primary)),
          ),
        ],
      ),
    );
    passwordController.dispose();
    if (password == null || password.trim().isEmpty || !mounted) return;

    final delayDays = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Когда удалить?', style: TextStyle(color: GE.text)),
        content: Text(
          'Можно удалить данные сразу или оставить аккаунт ещё на 7 дней.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 7),
            child: Text('Через 7 дней', style: TextStyle(color: GE.primary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 0),
            child: Text('Удалить сейчас', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    if (delayDays == null || !mounted) return;

    try {
      // Verify through the Social challenge protocol. The core delete endpoint
      // does not consume a password, so never include the entered value there.
      await ApiClient().verifyOwnPassword(password);
      final result = await ApiClient().coreDelete('/account', {
        'delay_days': delayDays,
      });
      if (!mounted) return;
      if (result is Map && result['scheduled'] == true) {
        toast.show('Аккаунт будет удалён через 7 дней');
        return;
      }
      await AuthService.logout();
      widget.onLogout?.call();
    } catch (e) {
      if (mounted) toast.show('Не удалось удалить аккаунт: $e');
    }
  }

  /// disabled=true — видно, но неактивно (не убираем совсем): для гостя
  /// разделы, требующие сервер (например "Устройства").
  Widget _row(
    IconData icon,
    String title,
    String sub,
    VoidCallback? onTap, {
    bool last = false,
    bool disabled = false,
    String searchTerms = '',
  }) {
    if (!_matchesSettingEntry(title, sub, searchTerms: searchTerms)) {
      return const SizedBox.shrink();
    }
    final iconColor = disabled ? GE.sub.withValues(alpha: 0.4) : GE.primary;
    final textColor = disabled ? GE.sub.withValues(alpha: 0.5) : GE.text;
    return Column(
      children: [
        PressScale(
          onTap: disabled || _reorderMode ? null : onTap,
          onLongPress: disabled || onTap == null ? null : _enterReorderMode,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(icon, size: 20, color: iconColor),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (ThemeService.instance.showDetailedDescriptions &&
                          sub.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          disabled ? 'Недоступно гостю' : sub,
                          style: TextStyle(
                            color: GE.sub.withValues(alpha: disabled ? 0.6 : 1),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!disabled && onTap != null)
                  Icon(CupertinoIcons.chevron_right, color: GE.sub, size: 20),
              ],
            ),
          ),
        ),
        if (!last) Divider(height: 1, color: GE.glassBorder, indent: 48),
      ],
    );
  }
}

// ─── Режим перестановки категорий прямо в списке (in-place, без шторки) ─────
// Долгое нажатие на любую строку настроек включает этот режим (см.
// _SettingsScreenState._enterReorderMode): весь список "отъезжает" вправо,
// слева у каждой категории появляется анимированная ручка для драга.
// ReorderableListView сам умеет автоскролл к краям экрана во время драга.
class _ReorderList extends StatelessWidget {
  final List<String> order;
  final Map<String, Widget> blocks;
  final double bottomPad;
  final void Function(int oldIndex, int newIndex) onReorder;

  const _ReorderList({
    super.key,
    required this.order,
    required this.blocks,
    required this.bottomPad,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      padding: EdgeInsets.fromLTRB(12, 12, 12, bottomPad),
      itemCount: order.length,
      onReorderItem: onReorder,
      itemBuilder: (context, i) {
        final key = order[i];
        return _ReorderItem(
          key: ValueKey(key),
          index: i,
          child: blocks[key] ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

class _ReorderItem extends StatelessWidget {
  final int index;
  final Widget child;
  const _ReorderItem({super.key, required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Ручка появляется с анимацией (fade+slide) при входе в режим —
          // сам ReorderableListView.builder пересоздаёт item'ы каждый build,
          // поэтому TweenAnimationBuilder с begin:0 стартует анимацию
          // заново на каждый вход в reorder-режим, как и задумано.
          ReorderableDragStartListener(
            index: index,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              builder: (context, t, _) => Opacity(
                opacity: t,
                child: Padding(
                  padding: EdgeInsets.only(top: 26, right: 6 * t),
                  child: Icon(
                    CupertinoIcons.line_horizontal_3,
                    size: 20,
                    color: GE.sub,
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Форма редактирования поля владеет своим controller'ом.
///
/// Важно не создавать controller в вызывающем State: Future bottom-sheet
/// завершается в момент pop, когда уходящая route ещё может быть в дереве на
/// один кадр. Тогда ранний dispose ломает EditableText и приводит к
/// `InheritedElement.debugDeactivated` (`framework.dart:6268`).
class _ProfileTextValueSheet extends StatefulWidget {
  final String title;
  final String hint;
  final String initial;
  final IconData icon;
  final bool obscure;
  final bool autocorrect;
  final TextInputType? keyboardType;
  final int maxLines;
  final int? maxLength;

  const _ProfileTextValueSheet({
    required this.title,
    required this.hint,
    required this.initial,
    required this.icon,
    required this.obscure,
    required this.autocorrect,
    required this.keyboardType,
    required this.maxLines,
    required this.maxLength,
  });

  @override
  State<_ProfileTextValueSheet> createState() => _ProfileTextValueSheetState();
}

class _ProfileTextValueSheetState extends State<_ProfileTextValueSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _close([String? value]) {
    // Сначала снимаем фокус с EditableText, затем закрываем route. Сам
    // controller освободится в dispose после фактического удаления sheet.
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: TextStyle(
              color: GE.text,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          _ProfileEditorField(
            controller: _controller,
            hint: widget.hint,
            icon: widget.icon,
            obscure: widget.obscure,
            keyboardType: widget.keyboardType,
            maxLines: widget.maxLines,
            maxLength: widget.maxLength,
            autocorrect: widget.autocorrect,
            autofocus: true,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: GlassButton(label: 'Отмена', onTap: _close),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GlassButton(
                  label: 'Сохранить',
                  primary: true,
                  onTap: () => _close(_controller.text),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Отдельное поле профиля.
///
/// Здесь намеренно нет GlassInput/TextFormField и нет свойства maxLength:
/// Flutter добавляет к TextFormField служебную строку счётчика и меняет
/// расчёт высоты декорации. Лимит задаётся только formatter'ом, поэтому поле
/// остаётся обычным компактным TextField независимо от числа символов.
class _ProfileEditorField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final bool autocorrect;
  final TextInputType? keyboardType;
  final int maxLines;
  final int? maxLength;
  final bool autofocus;

  const _ProfileEditorField({
    required this.controller,
    required this.hint,
    required this.icon,
    required this.obscure,
    required this.autocorrect,
    required this.keyboardType,
    required this.maxLines,
    required this.maxLength,
    required this.autofocus,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        ThemeService.instance.liquidGlassNotifier,
        ThemeService.instance.glassTintNotifier,
        ThemeService.instance.matteGlassNotifier,
        PerformanceService.instance.reducedEffectsNotifier,
      ]),
      builder: (context, _) {
        final reducedEffects = PerformanceService.instance.reducedEffects;
        final liquid =
            ThemeService.instance.liquidGlassNotifier.value && !reducedEffects;
        final matte =
            ThemeService.instance.matteGlassNotifier.value && !reducedEffects;
        final tint = ThemeService.instance.glassTintNotifier.value;
        final flat =
            ThemeService.instance.styleNotifier.value != ThemeStyle.vivid ||
            reducedEffects;
        final radius = BorderRadius.circular(GE.radiusSm);

        return ClipRRect(
          borderRadius: radius,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tint || liquid || matte
                  ? GE.glassFill.withValues(alpha: tint ? 0.45 : 0.32)
                  : Colors.transparent,
              border: Border.all(
                color: flat ? GE.border : GE.glassBorder,
                width: 0.7,
              ),
              borderRadius: radius,
            ),
            child: TextField(
              controller: controller,
              autofocus: autofocus,
              enabled: true,
              obscureText: obscure,
              obscuringCharacter: '•',
              keyboardType:
                  keyboardType ??
                  (maxLines > 1 ? TextInputType.multiline : TextInputType.text),
              textInputAction: maxLines > 1
                  ? TextInputAction.newline
                  : TextInputAction.done,
              autocorrect: autocorrect,
              enableSuggestions: !obscure && autocorrect,
              inputFormatters: [
                if (maxLength != null)
                  LengthLimitingTextInputFormatter(maxLength!),
              ],
              minLines: 1,
              maxLines: obscure ? 1 : maxLines,
              textAlignVertical: maxLines > 1
                  ? TextAlignVertical.top
                  : TextAlignVertical.center,
              cursorColor: GE.primary,
              cursorWidth: 1.2,
              style: TextStyle(
                color: GE.text,
                fontSize: 14,
                height: 1.25,
                fontWeight: FontWeight.normal,
              ),
              strutStyle: const StrutStyle(
                fontSize: 14,
                height: 1.25,
                forceStrutHeight: true,
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: hint,
                hintStyle: TextStyle(
                  color: GE.sub,
                  fontSize: 14,
                  height: 1.25,
                  fontWeight: FontWeight.normal,
                ),
                prefixIcon: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 12, end: 8),
                  child: Icon(icon, size: 18, color: GE.sub),
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 0,
                  minHeight: 0,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── Helper: каркас раздела ───────────────────────────────────────────────────
class _SectionScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  final VoidCallback? onBack;
  const _SectionScaffold({
    required this.title,
    required this.children,
    this.actions,
    this.onBack,
  });
  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(
          showBack: true,
          leading: onBack == null
              ? null
              : BackButton(onPressed: onBack, color: GE.text),
          titleText: title,
          actions: actions,
        ),
        body: ListView(padding: const EdgeInsets.all(12), children: children),
      ),
    );
  }
}

// ─── Безопасность → Приватность ──────────────────────────────────────────────
class _PrivacyScreen extends StatefulWidget {
  const _PrivacyScreen();

  @override
  State<_PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<_PrivacyScreen> {
  bool _addExpanded = false;

  @override
  Widget build(BuildContext context) {
    return _SectionScaffold(
      title: 'Приватность',
      children: [
        _sectionTitle('Кто может видеть вашу активность'),
        const _PrivacySwitchRow(
          icon: CupertinoIcons.circle,
          title: 'Показывать статус «в сети»',
          description: 'Если выключить, другие не увидят, что вы подключены.',
          listenable: _PrivacySetting.online,
        ),
        const SizedBox(height: 8),
        const _PrivacySwitchRow(
          icon: CupertinoIcons.checkmark_circle,
          title: 'Показывать, что сообщения прочитаны',
          description:
              'Если выключить, собеседники не увидят статус прочтения.',
          listenable: _PrivacySetting.readReceipts,
        ),
        const SizedBox(height: 20),
        _PrivacyAudienceRow(
          icon: CupertinoIcons.phone,
          title: 'Кто может звонить',
          listenable: PrivacySettings.instance.callPrivacyNotifier,
          onChanged: PrivacySettings.instance.setCallPrivacy,
        ),
        const SizedBox(height: 20),
        _sectionTitle('Безопасность'),
        GlassCard(
          isListSection: true,
          child: Column(
            children: [
              _tile(
                CupertinoIcons.person_2,
                'Кто может писать мне',
                () => _chooseAudience(
                  context,
                  title: 'Кто может писать мне',
                  listenable: PrivacySettings.instance.messagePrivacyNotifier,
                  onChanged: PrivacySettings.instance.setMessagePrivacy,
                ),
                sub: 'Все, контакты или никто',
              ),
              _tile(
                CupertinoIcons.person_badge_plus,
                'Кто может добавлять меня',
                () => setState(() => _addExpanded = !_addExpanded),
                sub: 'Отдельно для групп и каналов',
                trailingIcon: _addExpanded
                    ? CupertinoIcons.chevron_up
                    : CupertinoIcons.chevron_down,
                last: !_addExpanded,
              ),
              if (_addExpanded) ...[
                _PrivacySwitchRow(
                  icon: CupertinoIcons.person_2_fill,
                  title: 'Добавлять в группы',
                  description:
                      'Если выключено, вместо добавления отправляется приглашение-ссылка.',
                  listenable: _PrivacySetting.groupAdd,
                ),
                _PrivacySwitchRow(
                  icon: CupertinoIcons.antenna_radiowaves_left_right,
                  title: 'Добавлять в каналы',
                  description:
                      'Если выключено, вместо добавления отправляется приглашение-ссылка.',
                  listenable: _PrivacySetting.channelAdd,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        _sectionTitle('Видимость профиля'),
        _PrivacyAudienceRow(
          icon: CupertinoIcons.at,
          title: 'Юзернейм',
          listenable: PrivacySettings.instance.usernameVisibilityNotifier,
          onChanged: PrivacySettings.instance.setUsernameVisibility,
        ),
        _PrivacyAudienceRow(
          icon: CupertinoIcons.person,
          title: 'Имя',
          listenable: PrivacySettings.instance.displayNameVisibilityNotifier,
          onChanged: PrivacySettings.instance.setDisplayNameVisibility,
        ),
        _PrivacyAudienceRow(
          icon: CupertinoIcons.photo,
          title: 'Аватарка',
          listenable: PrivacySettings.instance.avatarVisibilityNotifier,
          onChanged: PrivacySettings.instance.setAvatarVisibility,
        ),
        _PrivacyAudienceRow(
          icon: CupertinoIcons.rectangle,
          title: 'Баннер',
          listenable: PrivacySettings.instance.bannerVisibilityNotifier,
          onChanged: PrivacySettings.instance.setBannerVisibility,
        ),
        _PrivacyAudienceRow(
          icon: CupertinoIcons.text_alignleft,
          title: 'Описание',
          listenable: PrivacySettings.instance.aboutVisibilityNotifier,
          onChanged: PrivacySettings.instance.setAboutVisibility,
        ),
        _PrivacyAudienceRow(
          icon: CupertinoIcons.music_note,
          title: 'Музыка профиля',
          listenable: PrivacySettings.instance.musicVisibilityNotifier,
          onChanged: PrivacySettings.instance.setMusicVisibility,
        ),
        const SizedBox(height: 20),
        if (ThemeService.instance.showDetailedDescriptions)
          GlassCard(
            strong: true,
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(CupertinoIcons.lock_shield, color: GE.primary, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Настройки применяются для этого аккаунта на всех устройствах.',
                    style: TextStyle(
                      color: GE.sub,
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _chooseAudience(
    BuildContext context, {
    required String title,
    required ValueListenable<PrivacyAudience> listenable,
    required Future<void> Function(PrivacyAudience) onChanged,
  }) async {
    final current = listenable.value;
    final selected = await showModalBottomSheet<PrivacyAudience>(
      context: context,
      backgroundColor: GE.bgDeep,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            for (final value in PrivacyAudience.values)
              ListTile(
                leading: Icon(
                  value == current
                      ? CupertinoIcons.checkmark_circle_fill
                      : CupertinoIcons.circle,
                  color: value == current ? GE.primary : GE.sub,
                ),
                title: Text(value.label, style: TextStyle(color: GE.text)),
                onTap: () => Navigator.pop(sheetContext, value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected != null) unawaited(onChanged(selected));
  }
}

enum _PrivacySetting { online, readReceipts, channelAdd, groupAdd }

class _PrivacySwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final _PrivacySetting listenable;

  const _PrivacySwitchRow({
    required this.icon,
    required this.title,
    required this.description,
    required this.listenable,
  });

  ValueListenable<bool> get _valueListenable => switch (listenable) {
    _PrivacySetting.online => PrivacySettings.instance.showOnlineNotifier,
    _PrivacySetting.readReceipts =>
      PrivacySettings.instance.readReceiptsNotifier,
    _PrivacySetting.channelAdd =>
      PrivacySettings.instance.allowChannelAddNotifier,
    _PrivacySetting.groupAdd => PrivacySettings.instance.allowGroupAddNotifier,
  };

  Future<void> _setValue(bool value) => switch (listenable) {
    _PrivacySetting.online => PrivacySettings.instance.setShowOnline(value),
    _PrivacySetting.readReceipts =>
      PrivacySettings.instance.setSendReadReceipts(value),
    _PrivacySetting.channelAdd => PrivacySettings.instance.setAllowChannelAdd(
      value,
    ),
    _PrivacySetting.groupAdd => PrivacySettings.instance.setAllowGroupAdd(
      value,
    ),
  };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _valueListenable,
      builder: (context, enabled, _) {
        return GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            children: [
              Icon(icon, color: GE.primary, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (ThemeService.instance.showDetailedDescriptions) ...[
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: TextStyle(color: GE.sub, fontSize: 11.5),
                      ),
                    ],
                  ],
                ),
              ),
              GhostSwitch(
                value: enabled,
                activeColor: GE.primary,
                onChanged: (value) => unawaited(_setValue(value)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PrivacyAudienceRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final ValueListenable<PrivacyAudience> listenable;
  final Future<void> Function(PrivacyAudience) onChanged;

  const _PrivacyAudienceRow({
    required this.icon,
    required this.title,
    required this.listenable,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PrivacyAudience>(
      valueListenable: listenable,
      builder: (context, value, _) => GlassCard(
        isListSection: true,
        padding: EdgeInsets.zero,
        child: ListTile(
          leading: Icon(icon, color: GE.primary, size: 20),
          title: Text(title, style: TextStyle(color: GE.text, fontSize: 14)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(value.label, style: TextStyle(color: GE.sub, fontSize: 12)),
              const SizedBox(width: 5),
              Icon(CupertinoIcons.chevron_right, color: GE.sub, size: 18),
            ],
          ),
          onTap: () async {
            final selected = await showModalBottomSheet<PrivacyAudience>(
              context: context,
              backgroundColor: GE.bgDeep,
              builder: (sheetContext) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final option in PrivacyAudience.values)
                      ListTile(
                        leading: Icon(
                          option == value
                              ? CupertinoIcons.checkmark_circle_fill
                              : CupertinoIcons.circle,
                          color: option == value ? GE.primary : GE.sub,
                        ),
                        title: Text(
                          option.label,
                          style: TextStyle(color: GE.text),
                        ),
                        onTap: () => Navigator.pop(sheetContext, option),
                      ),
                  ],
                ),
              ),
            );
            if (selected != null) unawaited(onChanged(selected));
          },
        ),
      ),
    );
  }
}

Widget _sectionTitle(String t, {bool beta = false}) => Padding(
  padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
  child: Row(
    children: [
      if (beta) ...[
        Icon(CupertinoIcons.sparkles, size: 14, color: GE.primary),
        const SizedBox(width: 6),
      ],
      Text(
        t.toUpperCase(),
        style: TextStyle(
          color: beta ? GE.primary : GE.sub,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    ],
  ),
);

/// onTap=null → чисто информационная строка: без риппла и без шеврона (не
/// обещает взаимодействие, на которое нет реакции). trailingIcon переопределяет
/// шеврон (например на "скопировать" или "внешняя ссылка").
Widget _tile(
  IconData icon,
  String label,
  VoidCallback? onTap, {
  String? sub,
  bool danger = false,
  IconData? trailingIcon,
  bool last = false,
}) {
  final color = danger ? GE.red : GE.primary;
  final textColor = danger ? GE.red : GE.text;
  final content = Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    child: Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: textColor, fontSize: 14)),
              if (sub != null &&
                  ThemeService.instance.showDetailedDescriptions) ...[
                const SizedBox(height: 2),
                Text(sub, style: TextStyle(color: GE.sub, fontSize: 11)),
              ],
            ],
          ),
        ),
        if (onTap != null)
          Icon(
            trailingIcon ?? CupertinoIcons.chevron_right,
            color: GE.sub,
            size: 20,
          ),
      ],
    ),
  );
  final tile = onTap == null
      ? content
      : PressScale(onTap: onTap, child: content);
  if (last) return tile;
  return Column(
    children: [
      tile,
      Divider(height: 1, color: GE.glassBorder, indent: 44),
    ],
  );
}

// ─── Раздел: Внешний вид ──────────────────────────────────────────────────────
class _AppearanceScreen extends StatefulWidget {
  final String? initialPanel;

  const _AppearanceScreen({this.initialPanel});
  @override
  State<_AppearanceScreen> createState() => _AppearanceScreenState();
}

class _AppearanceScreenState extends State<_AppearanceScreen> {
  String? _panel;
  @override
  void initState() {
    super.initState();
    _panel = widget.initialPanel;
    ThemeService.instance.notifier.addListener(_onTheme);
    ThemeService.instance.detailedDescriptionsNotifier.addListener(_onTheme);
    // Скругление живёт в отдельном notifier (не дублирует palette-рёбилды) —
    // без этой подписки карточки тем на этом экране не подхватывают новый
    // радиус, пока слайдер двигают (только его собственный превью-кружок).
    ThemeService.instance.cornerNotifier.addListener(_onTheme);
    ThemeService.instance.avatarBannerBufferNotifier.addListener(_onTheme);
    // Свои темы — отдельный список, создание/переименование/удаление не
    // трогает notifier (активная тема может и не меняться), без этой
    // подписки сетка тем не подхватит новый черновик/удаление.
    ThemeService.instance.customPresetsNotifier.addListener(_onTheme);
  }

  @override
  void dispose() {
    ThemeService.instance.notifier.removeListener(_onTheme);
    ThemeService.instance.detailedDescriptionsNotifier.removeListener(_onTheme);
    ThemeService.instance.cornerNotifier.removeListener(_onTheme);
    ThemeService.instance.avatarBannerBufferNotifier.removeListener(_onTheme);
    ThemeService.instance.customPresetsNotifier.removeListener(_onTheme);
    super.dispose();
  }

  void _onTheme() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final panel = _panel;
    return _SectionScaffold(
      title: 'Внешний вид',
      onBack: panel == null ? null : () => setState(() => _panel = null),
      children: panel == null ? _appearanceMenu() : _appearancePanel(panel),
    );
  }

  List<Widget> _appearanceMenu() => [
    _sectionTitle('Разделы'),
    _appearanceRow(
      CupertinoIcons.paintbrush,
      'Тема и стиль',
      'Основная тема, стиль поверхностей и скругление',
      'style',
    ),
    _appearanceRow(
      CupertinoIcons.person_crop_rectangle,
      'Профиль',
      'Баннер и вид музыки в профиле',
      'profile',
    ),
    _appearanceRow(
      CupertinoIcons.rectangle,
      'Нижний бар',
      'Фон, подписи, выделение и анимация выбранной категории',
      'navbar',
    ),
    _appearanceRow(
      CupertinoIcons.music_note_2,
      'Проигрыватель',
      'Матовое стекло, размер и положение глобального плеера',
      'player',
    ),
    _appearanceRow(
      CupertinoIcons.circle_lefthalf_fill,
      'Анимированный фон',
      'Mesh-фон, скорость и реакция на касание',
      'background',
    ),
    _appearanceRow(
      CupertinoIcons.chat_bubble_2,
      'Сообщения',
      'Время, подписи и элементы списка',
      'messages',
    ),
    _appearanceRow(
      CupertinoIcons.speedometer,
      'Производительность',
      'Качество анимаций и интерфейса',
      'performance',
    ),
    _appearanceRow(
      CupertinoIcons.slider_horizontal_3,
      'Другое',
      'Заголовок вкладки «Чаты»',
      'other',
    ),
  ];

  Widget _appearanceRow(
    IconData icon,
    String title,
    String description,
    String panel,
  ) => GlassCard(
    isListSection: true,
    padding: EdgeInsets.zero,
    child: ListTile(
      leading: Icon(icon, color: GE.primary),
      title: Text(title, style: TextStyle(color: GE.text, fontSize: 14)),
      subtitle: ThemeService.instance.showDetailedDescriptions
          ? Text(description, style: TextStyle(color: GE.sub, fontSize: 11))
          : null,
      trailing: Icon(CupertinoIcons.chevron_right, color: GE.sub),
      onTap: () => setState(() => _panel = panel),
    ),
  );

  List<Widget> _appearancePanel(String panel) => [
    if (panel == 'style') ...[
      _sectionTitle('Стиль'),
      _StyleSwitcher(),
      const SizedBox(height: 20),
      _sectionTitle('Подписи'),
      _DetailedDescriptionsToggleRow(),
      const SizedBox(height: 20),
      _sectionTitle('Тема'),
      _ThemeGrid(),
      const SizedBox(height: 20),
      _sectionTitle('Скругление'),
      _CornerRadiusSlider(),
      const SizedBox(height: 20),
      _sectionTitle('Поверхности'),
      _ListPlatesToggleRow(),
      const SizedBox(height: 8),
    ],
    if (panel == 'profile') ...[
      _sectionTitle('Профиль'),
      const _ProfileMusicWidgetStyleRow(),
      const SizedBox(height: 12),
      _sectionTitle('Баннер'),
      _AvatarBannerBufferSlider(),
      if (ThemeService.instance.showDetailedDescriptions) ...[
        const SizedBox(height: 10),
        Text(
          'Настройка применяется к профилю пользователя, группам и редактору баннера.',
          style: TextStyle(color: GE.sub, fontSize: 12, height: 1.35),
        ),
      ],
    ],
    if (panel == 'navbar') ...[
      _sectionTitle('Нижний бар'),
      const _NavBarAppearanceControls(),
    ],
    if (panel == 'player') ...[
      _sectionTitle('Проигрыватель'),
      const _AudioPlayerAppearanceControls(),
    ],
    if (panel == 'background') ...[
      _sectionTitle('Анимированный фон'),
      _MeshToggleRow(),
      const SizedBox(height: 8),
      _MeshSpeedRow(),
      const SizedBox(height: 8),
      _MeshTouchReactionRow(),
    ],
    if (panel == 'messages') ...[
      _sectionTitle('Сообщения'),
      _PreciseMessageTimeRow(),
    ],
    if (panel == 'performance') ...[
      _sectionTitle('Производительность интерфейса'),
      _AppearancePerformanceControls(),
    ],
    if (panel == 'other') ...[
      _sectionTitle('Другое'),
      const _ChatHeaderTitleControls(),
    ],
  ];
}

class _AppAvatarAppearanceControls extends StatelessWidget {
  const _AppAvatarAppearanceControls();

  Future<void> _confirmApplyAndRestart(BuildContext context) async {
    final confirmed = await showGhostNativeConfirm(
      context: context,
      title: 'Применить аватар приложения?',
      message:
          'Приложение полностью перезапустится, чтобы применить новую аватарку.',
      confirmLabel: 'Применить',
    );
    if (confirmed != true || !context.mounted) return;
    await _applyAndRestart(context);
  }

  Future<void> _applyAndRestart(BuildContext context) async {
    final restarted = await AppAvatarSettings.instance.restartApp();
    if (!restarted && context.mounted) {
      toast.show('Перезапуск доступен только на Android');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppAvatarSettings.instance;
    return ValueListenableBuilder<int>(
      valueListenable: settings.selectedVariantNotifier,
      builder: (_, selected, _) {
        final selectedLabel = (selected + 1).toString().padLeft(2, '0');
        return Column(
          children: [
            GlassCard(
              isListSection: true,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Выбранный вариант',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: ClipRRect(
                      key: ValueKey(selected),
                      borderRadius: BorderRadius.circular(24),
                      child: Image.asset(
                        settings.assetPathFor(selected),
                        width: 132,
                        height: 132,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    'Вариант $selectedLabel',
                    style: TextStyle(color: GE.sub, fontSize: 12),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    settings.variantNameFor(selected),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: GE.text, fontSize: 12),
                  ),
                  if (ThemeService.instance.showDetailedDescriptions) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Первый вариант — исходная аватарка, остальные отличаются только спокойной палитрой.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: GE.sub, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            GlassCard(
              isListSection: true,
              padding: const EdgeInsets.all(12),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: AppAvatarSettings.variantCount,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  crossAxisSpacing: 9,
                  mainAxisSpacing: 10,
                  childAspectRatio: 0.82,
                ),
                itemBuilder: (_, index) {
                  final active = index == selected;
                  final label = (index + 1).toString().padLeft(2, '0');
                  return PressScale(
                    onTap: () => settings.setSelectedVariant(index),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(
                          color: active ? GE.primary : GE.glassBorder,
                          width: active ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(9),
                              child: Image.asset(
                                settings.assetPathFor(index),
                                width: double.infinity,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            label,
                            style: TextStyle(
                              color: active ? GE.primary : GE.sub,
                              fontSize: 10,
                              fontWeight: active
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            GlassButton(
              label: 'Применить и перезапустить',
              icon: CupertinoIcons.refresh,
              primary: true,
              fullWidth: true,
              onTap: () => unawaited(_confirmApplyAndRestart(context)),
            ),
            const SizedBox(height: 7),
            Text(
              'Внимание: после применения приложение полностью перезапустится.',
              textAlign: TextAlign.center,
              style: TextStyle(color: GE.sub, fontSize: 11),
            ),
          ],
        );
      },
    );
  }
}

class _ChatHeaderTitleControls extends StatelessWidget {
  const _ChatHeaderTitleControls();

  @override
  Widget build(BuildContext context) {
    final settings = ChatHeaderSettings.instance;
    return ValueListenableBuilder<ChatHeaderTitleMode>(
      valueListenable: settings.modeNotifier,
      builder: (_, selected, _) => GlassCard(
        isListSection: true,
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Заголовок вкладки «Чаты»',
              style: TextStyle(
                color: GE.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (ThemeService.instance.showDetailedDescriptions) ...[
              const SizedBox(height: 3),
              Text(
                'Выбери, что показывать слева в шапке списка чатов.',
                style: TextStyle(color: GE.sub, fontSize: 11.5),
              ),
            ],
            const SizedBox(height: 8),
            for (final mode in ChatHeaderTitleMode.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: InkWell(
                  borderRadius: BorderRadius.circular(GE.radiusSm),
                  onTap: () => unawaited(settings.setMode(mode)),
                  child: AnimatedContainer(
                    duration: PerformanceService.instance.animationDuration(
                      const Duration(milliseconds: 160),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: selected == mode
                          ? GE.primary.withValues(alpha: 0.14)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(GE.radiusSm),
                      border: Border.all(
                        color: selected == mode
                            ? GE.primary.withValues(alpha: 0.7)
                            : GE.glassBorder,
                        width: selected == mode ? 1.1 : 0.8,
                      ),
                    ),
                    child: Row(
                      children: [
                        AnimatedContainer(
                          duration: PerformanceService.instance
                              .animationDuration(
                                const Duration(milliseconds: 160),
                              ),
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected == mode ? GE.primary : GE.sub,
                              width: 1.4,
                            ),
                          ),
                          child: selected == mode
                              ? Center(
                                  child: Container(
                                    width: 9,
                                    height: 9,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: GE.primary,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                mode.label,
                                style: TextStyle(
                                  color: selected == mode
                                      ? GE.primary
                                      : GE.text,
                                  fontSize: 13,
                                  fontWeight: selected == mode
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                              if (ThemeService
                                  .instance
                                  .showDetailedDescriptions)
                                Text(
                                  mode.description,
                                  style: TextStyle(color: GE.sub, fontSize: 11),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Постоянные визуальные настройки обычного режима. Профиль
/// энергосбережения хранит отдельные overrides и временно подменяет их,
/// пока активен — поэтому пользователь может настроить внешний вид, не
/// ломая экономичный профиль.
class _AppearancePerformanceControls extends StatelessWidget {
  const _AppearancePerformanceControls();

  String _fpsLabel(int fps) => '$fps FPS';

  String _animationLabel(AnimationQuality quality) => switch (quality) {
    AnimationQuality.best => 'Лучшее',
    AnimationQuality.standard => 'Обычное',
    AnimationQuality.none => 'Без анимаций',
  };

  String _guiLabel(GuiQuality quality) => switch (quality) {
    GuiQuality.best => 'Лучшее',
    GuiQuality.low => 'Низкое',
  };

  Widget _choiceCard<T>({
    required String title,
    required String description,
    required List<T> options,
    required T selected,
    required String Function(T) label,
    required ValueChanged<T> onChanged,
  }) {
    return GlassCard(
      isListSection: true,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: GE.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (ThemeService.instance.showDetailedDescriptions) ...[
            const SizedBox(height: 3),
            Text(description, style: TextStyle(color: GE.sub, fontSize: 11.5)),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < options.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: _choiceButton(
                    label(options[i]),
                    options[i] == selected,
                    () => onChanged(options[i]),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _choiceButton(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: PerformanceService.instance.animationDuration(
          const Duration(milliseconds: 160),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? GE.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(GE.radiusSm),
          border: Border.all(
            color: selected ? GE.primary : GE.glassBorder,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? GE.primary : GE.sub,
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final performance = PerformanceService.instance;
    return Column(
      children: [
        ValueListenableBuilder<int>(
          valueListenable: performance.appearanceBackgroundFpsNotifier,
          builder: (context, fps, _) => _choiceCard<int>(
            title: 'FPS фона',
            description:
                'Частота обновления mesh-фона в обычном режиме. Энергосбережение использует свой профиль.',
            options: PerformanceService.backgroundFpsOptions,
            selected: fps,
            label: _fpsLabel,
            onChanged: performance.setAppearanceBackgroundFps,
          ),
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<AnimationQuality>(
          valueListenable: performance.appearanceAnimationQualityNotifier,
          builder: (context, quality, _) => _choiceCard<AnimationQuality>(
            title: 'Качество анимаций',
            description:
                'Применяется в обычном режиме. Профиль энергосбережения может использовать своё значение.',
            options: AnimationQuality.values,
            selected: quality,
            label: _animationLabel,
            onChanged: performance.setAppearanceAnimationQuality,
          ),
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<GuiQuality>(
          valueListenable: performance.appearanceGuiQualityNotifier,
          builder: (context, quality, _) => _choiceCard<GuiQuality>(
            title: 'Качество GUI',
            description:
                'Качество blur/стекла, градиентов, свечений и теней в обычном режиме. Энергосбережение может снизить его отдельно.',
            options: GuiQuality.values,
            selected: quality,
            label: _guiLabel,
            onChanged: performance.setAppearanceGuiQuality,
          ),
        ),
      ],
    );
  }
}

// ─── Раздел: Энергосбережение ────────────────────────────────────────────────
class _PowerSavingScreen extends StatefulWidget {
  const _PowerSavingScreen();

  @override
  State<_PowerSavingScreen> createState() => _PowerSavingScreenState();
}

class _PowerSavingScreenState extends State<_PowerSavingScreen> {
  final _lanSettings = LanSettings();
  bool _lanLoading = true;
  int? _thresholdDraft;

  @override
  void initState() {
    super.initState();
    ThemeService.instance.detailedDescriptionsNotifier.addListener(_refresh);
    _lanSettings.load().then((_) {
      if (mounted) setState(() => _lanLoading = false);
    });
  }

  @override
  void dispose() {
    ThemeService.instance.detailedDescriptionsNotifier.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String _fpsLabel(int fps) => '$fps FPS';

  String _animationLabel(AnimationQuality quality) => switch (quality) {
    AnimationQuality.best => 'Лучшее',
    AnimationQuality.standard => 'Обычное',
    AnimationQuality.none => 'Без анимаций',
  };

  String _guiLabel(GuiQuality quality) => switch (quality) {
    GuiQuality.best => 'Лучшее',
    GuiQuality.low => 'Низкое',
  };

  Widget _choiceCard<T>({
    required String title,
    required String description,
    required List<T> options,
    required T selected,
    required String Function(T) label,
    required ValueChanged<T> onChanged,
  }) {
    return GlassCard(
      isListSection: true,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: GE.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (ThemeService.instance.showDetailedDescriptions) ...[
            const SizedBox(height: 3),
            Text(description, style: TextStyle(color: GE.sub, fontSize: 11.5)),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < options.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: _choiceButton(
                    label(options[i]),
                    options[i] == selected,
                    () => onChanged(options[i]),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _choiceButton(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: PerformanceService.instance.animationDuration(
          const Duration(milliseconds: 160),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? GE.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(GE.radiusSm),
          border: Border.all(
            color: selected ? GE.primary : GE.glassBorder,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? GE.primary : GE.sub,
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _switchCard({
    required String title,
    required String description,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return GlassCard(
      isListSection: true,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (ThemeService.instance.showDetailedDescriptions) ...[
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(color: GE.sub, fontSize: 11.5),
                  ),
                ],
              ],
            ),
          ),
          GhostSwitch(
            value: value,
            activeColor: GE.primary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _sliderCard({
    required String title,
    required String description,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String valueLabel,
    required ValueChanged<double> onChanged,
    ValueChanged<double>? onChangeStart,
    ValueChanged<double>? onChangeEnd,
  }) {
    return GlassCard(
      isListSection: true,
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                valueLabel,
                style: TextStyle(color: GE.primary, fontSize: 12),
              ),
            ],
          ),
          if (ThemeService.instance.showDetailedDescriptions) ...[
            const SizedBox(height: 2),
            Text(description, style: TextStyle(color: GE.sub, fontSize: 11.5)),
          ],
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            activeColor: GE.primary,
            inactiveColor: GE.border,
            onChangeStart: onChangeStart,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final performance = PerformanceService.instance;
    return _SectionScaffold(
      title: 'Энергосбережение',
      children: [
        AnimatedBuilder(
          animation: Listenable.merge([
            performance.energySavingActiveNotifier,
            performance.manualEnergySavingNotifier,
            performance.batteryLevelNotifier,
            performance.automaticEnergySavingNotifier,
            performance.batteryThresholdNotifier,
            performance.systemPowerSaveNotifier,
            performance.thermalProtectionNotifier,
            performance.backgroundFpsNotifier,
            performance.animationQualityNotifier,
            performance.guiQualityNotifier,
            performance.energyMeshEnabledNotifier,
            performance.energyMeshSpeedNotifier,
          ]),
          builder: (context, _) {
            final active = performance.energySavingActive;
            final automatic = performance.automaticEnergySavingNotifier.value;
            final manual = performance.manualEnergySaving;
            final manuallyDisabled = performance.manualEnergySavingDisabled;
            final level = performance.batteryLevelNotifier.value;
            final threshold = performance.batteryThresholdNotifier.value;
            final status = manual
                ? active
                      ? 'Профиль энергосбережения включён вручную${level == null ? '' : ' · заряд $level%'}.'
                      : 'Профиль энергосбережения включится через мгновение.'
                : manuallyDisabled
                ? 'Профиль вручную выключен и не включится снова до 5% или нового пересечения порога.'
                : !automatic
                ? 'Автоматическое энергосбережение выключено. Выбранный профиль не применяется.'
                : active
                ? 'Профиль энергосбережения активен сейчас${level == null ? '' : ' · заряд $level%'}.'
                : 'Профиль включится при заряде ≤ $threshold%${performance.systemPowerSaveNotifier.value ? ', системном энергосбережении' : ''}${performance.thermalProtectionNotifier.value ? ' или перегреве' : ''}.';
            return Column(
              children: [
                GlassCard(
                  strong: true,
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        active ? Icons.battery_saver : Icons.battery_std,
                        color: active ? GE.primary : GE.sub,
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          status,
                          style: TextStyle(
                            color: GE.sub,
                            fontSize: 12.5,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                GlassCard(
                  isListSection: true,
                  padding: const EdgeInsets.all(10),
                  child: GlassButton(
                    label: active ? 'Выключить сейчас' : 'Включить сейчас',
                    icon: active ? Icons.battery_std : Icons.battery_saver,
                    primary: !active,
                    fullWidth: true,
                    onTap: () => performance.setManualEnergySaving(!active),
                  ),
                ),
                _sectionTitle('Автоматический режим'),
                _switchCard(
                  title: 'Автоматически включать',
                  description:
                      'Если выключить, приложение никогда само не перейдёт на профиль энергосбережения.',
                  value: automatic,
                  onChanged: performance.setAutomaticEnergySaving,
                ),
                const SizedBox(height: 8),
                _sliderCard(
                  title: 'Порог включения по заряду',
                  description:
                      'Профиль включается, когда заряд становится равен этому значению или ниже.',
                  value: (_thresholdDraft ?? threshold).toDouble(),
                  min: PerformanceService.minBatteryThreshold.toDouble(),
                  max: PerformanceService.maxBatteryThreshold.toDouble(),
                  divisions:
                      PerformanceService.maxBatteryThreshold -
                      PerformanceService.minBatteryThreshold,
                  valueLabel: '≤ ${_thresholdDraft ?? threshold}%',
                  onChangeStart: (_) {
                    if (_thresholdDraft == null) {
                      setState(() => _thresholdDraft = threshold);
                    }
                  },
                  onChanged: (value) {
                    final next = value.round().clamp(
                      PerformanceService.minBatteryThreshold,
                      PerformanceService.maxBatteryThreshold,
                    );
                    if (_thresholdDraft != next) {
                      setState(() => _thresholdDraft = next);
                    }
                  },
                  onChangeEnd: (value) {
                    final next = value.round().clamp(
                      PerformanceService.minBatteryThreshold,
                      PerformanceService.maxBatteryThreshold,
                    );
                    setState(() => _thresholdDraft = null);
                    // Меняем порог и пересчитываем профиль только после
                    // отпускания пальца, а не на каждом пикселе свайпа.
                    performance.setBatteryThreshold(next);
                  },
                ),
                const SizedBox(height: 8),
                _switchCard(
                  title: 'Учитывать системное энергосбережение',
                  description:
                      'Без этого переключателя системный режим Android не включит профиль на высоком заряде.',
                  value: performance.systemPowerSaveNotifier.value,
                  onChanged: automatic ? performance.setSystemPowerSave : null,
                ),
                const SizedBox(height: 8),
                _switchCard(
                  title: 'Учитывать перегрев',
                  description:
                      'Включать профиль при серьёзном thermal-режиме Android независимо от процента заряда.',
                  value: performance.thermalProtectionNotifier.value,
                  onChanged: automatic
                      ? performance.setThermalProtection
                      : null,
                ),
                _sectionTitle('Профиль энергосбережения'),
                ValueListenableBuilder<int>(
                  valueListenable: performance.backgroundFpsNotifier,
                  builder: (context, fps, _) => _choiceCard<int>(
                    title: 'FPS фона',
                    description:
                        'Применяется только при активном профиле. В обычном режиме mesh работает на полной частоте.',
                    options: PerformanceService.backgroundFpsOptions,
                    selected: fps,
                    label: _fpsLabel,
                    onChanged: performance.setBackgroundFps,
                  ),
                ),
                const SizedBox(height: 8),
                _switchCard(
                  title: 'Анимированный фон в энергосбережении',
                  description:
                      'Отдельно от Внешний вид: выключенный фон убирает точки, линии и фоновые градиенты только в профиле.',
                  value: performance.energyMeshEnabledNotifier.value,
                  onChanged: performance.setEnergyMeshEnabled,
                ),
                AnimatedSize(
                  duration: performance.animationDuration(
                    const Duration(milliseconds: 220),
                  ),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: performance.energyMeshEnabledNotifier.value
                      ? Padding(
                          key: const ValueKey('energy_mesh_speed'),
                          padding: const EdgeInsets.only(top: 8),
                          child: _sliderCard(
                            title: 'Скорость mesh-фона',
                            description:
                                'Скорость движения точек только в профиле энергосбережения.',
                            value: performance.energyMeshSpeedNotifier.value,
                            min: 0.25,
                            max: 2,
                            divisions: 7,
                            valueLabel:
                                '${performance.energyMeshSpeedNotifier.value.toStringAsFixed(2)}×',
                            onChanged: performance.setEnergyMeshSpeed,
                          ),
                        )
                      : const SizedBox(
                          key: ValueKey('energy_mesh_speed_hidden'),
                        ),
                ),
                const SizedBox(height: 8),
                _MeshTouchReactionRow(),
                _sectionTitle('Анимации'),
                ValueListenableBuilder<AnimationQuality>(
                  valueListenable: performance.animationQualityNotifier,
                  builder: (context, quality, _) => _choiceCard<AnimationQuality>(
                    title: 'Качество анимаций',
                    description:
                        'Профиль энергосбережения: лучшее — текущий motion, обычное — только короткие простые переходы, без анимаций — отключает ticker и splash.',
                    options: AnimationQuality.values,
                    selected: quality,
                    label: _animationLabel,
                    onChanged: performance.setAnimationQuality,
                  ),
                ),
                _sectionTitle('Интерфейс'),
                ValueListenableBuilder<GuiQuality>(
                  valueListenable: performance.guiQualityNotifier,
                  builder: (context, quality, _) => _choiceCard<GuiQuality>(
                    title: 'Качество GUI',
                    description:
                        'Низкое в профиле убирает blur/стекло, градиенты, свечения и тени карточек; обычный режим не меняется.',
                    options: GuiQuality.values,
                    selected: quality,
                    label: _guiLabel,
                    onChanged: performance.setGuiQuality,
                  ),
                ),
                _sectionTitle('Связь поблизости'),
                if (_lanLoading)
                  const SizedBox(height: 56)
                else
                  ValueListenableBuilder<bool>(
                    valueListenable: _lanSettings.pingEnabledNotifier,
                    builder: (context, enabled, _) => _switchCard(
                      title: 'LAN-пинг',
                      description:
                          'Проверять доступность устройств поблизости и поддерживать статус онлайн. При выключении текущие keepalive-таймеры сразу отменяются.',
                      value: enabled,
                      onChanged: _lanSettings.setLanPingEnabled,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ─── Раздел: Бета-функции ────────────────────────────────────────────────────
class _BetaFeaturesScreen extends StatefulWidget {
  const _BetaFeaturesScreen({this.initialQuery});

  final String? initialQuery;

  @override
  State<_BetaFeaturesScreen> createState() => _BetaFeaturesScreenState();
}

class _BetaFeaturesScreenState extends State<_BetaFeaturesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showBetaNotice();
    });
  }

  Future<void> _showBetaNotice() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        icon: Icon(CupertinoIcons.sparkles, color: GE.primary, size: 30),
        title: Text('Бета-функции', style: TextStyle(color: GE.text)),
        content: Text(
          'Возможности в этом разделе находятся в разработке. Они могут '
          'работать нестабильно, менять поведение или временно исчезать. '
          'Если что-то пойдёт не так, отключите функцию в её настройках.',
          style: TextStyle(color: GE.sub, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Понятно', style: TextStyle(color: GE.primary)),
          ),
        ],
      ),
    );
  }

  Widget _betaGlassRow(BuildContext context) {
    return PressScale(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const _GlassSettingsScreen())),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            Icon(CupertinoIcons.sparkles, size: 20, color: GE.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Стекло',
                    style: TextStyle(
                      color: GE.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (ThemeService.instance.showDetailedDescriptions) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Жидкая рефракция, тинт и матовость',
                      style: TextStyle(color: GE.sub, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
            Icon(CupertinoIcons.chevron_right, color: GE.sub, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _betaSoundRow(BuildContext context) {
    return PressScale(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const SoundSettingsScreen())),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            Icon(CupertinoIcons.speaker_2, size: 20, color: GE.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Звуки',
                    style: TextStyle(
                      color: GE.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (ThemeService.instance.showDetailedDescriptions) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Звуки интерфейса, уведомлений и звонков',
                      style: TextStyle(color: GE.sub, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
            Icon(CupertinoIcons.chevron_right, color: GE.sub, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _betaAvatarRow(BuildContext context) {
    return PressScale(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const _BetaAppAvatarScreen())),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            Icon(Icons.apps, size: 20, color: GE.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Аватар приложения',
                    style: TextStyle(
                      color: GE.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (ThemeService.instance.showDetailedDescriptions) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Оригинал и 19 цветовых вариантов с предпросмотром',
                      style: TextStyle(color: GE.sub, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
            Icon(CupertinoIcons.chevron_right, color: GE.sub, size: 20),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = (widget.initialQuery ?? '').trim().toLowerCase();
    final showGlass =
        query.isEmpty ||
        'стекло жидкая рефракция тинт матовость'.contains(query);
    final showSounds =
        query.isEmpty ||
        'звуки звук интерфейс уведомления звонки сигнал'.contains(query);
    final showAvatar =
        query.isEmpty ||
        'аватар приложения аватарка приложение иконка приложения иконка оригинальная цветовые варианты'
            .contains(query);
    final featureRows = <Widget>[
      if (showGlass) _betaGlassRow(context),
      if (showSounds) _betaSoundRow(context),
      if (showAvatar) _betaAvatarRow(context),
    ];
    return _SectionScaffold(
      title: 'Бета-функции',
      children: [
        if (ThemeService.instance.showDetailedDescriptions)
          GlassCard(
            strong: true,
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(CupertinoIcons.sparkles, color: GE.primary, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Экспериментальные функции могут быть нестабильны. '
                    'Их можно отключить в любой момент.',
                    style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        if (featureRows.isNotEmpty) ...[
          _sectionTitle('Экспериментальные возможности'),
          GlassCard(
            isListSection: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                for (var index = 0; index < featureRows.length; index++) ...[
                  if (index > 0)
                    Divider(height: 1, color: GE.glassBorder, indent: 14),
                  featureRows[index],
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _BetaAppAvatarScreen extends StatelessWidget {
  const _BetaAppAvatarScreen();

  @override
  Widget build(BuildContext context) {
    return _SectionScaffold(
      title: 'Аватар приложения',
      children: [
        _sectionTitle('Выбор аватарки'),
        const _AppAvatarAppearanceControls(),
      ],
    );
  }
}

// ─── Внешний вид → Стекло ────────────────────────────────────────────────────
class _GlassSettingsScreen extends StatelessWidget {
  const _GlassSettingsScreen();

  @override
  Widget build(BuildContext context) {
    return _SectionScaffold(
      title: 'Стекло',
      children: [
        _sectionTitle('Режим поверхности'),
        _LiquidGlassToggleRow(),
        const SizedBox(height: 8),
        _MatteGlassToggleRow(),
        const SizedBox(height: 20),
        _sectionTitle('Цвет и глубина'),
        _GlassTintToggleRow(),
      ],
    );
  }
}

class _DetailedDescriptionsToggleRow extends StatelessWidget {
  const _DetailedDescriptionsToggleRow();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.detailedDescriptionsNotifier,
      builder: (context, enabled, _) {
        return GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Подробные описания',
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              GhostSwitch(
                value: enabled,
                activeColor: GE.primary,
                onChanged: (v) =>
                    ThemeService.instance.setDetailedDescriptions(v),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LiquidGlassToggleRow extends StatelessWidget {
  const _LiquidGlassToggleRow();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.liquidGlassNotifier,
      builder: (context, enabled, _) {
        return GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Жидкая рефракция',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (ThemeService.instance.showDetailedDescriptions) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Нативная линза с преломлением краёв, как на лендинге',
                        style: TextStyle(color: GE.sub, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              GhostSwitch(
                value: enabled,
                activeColor: GE.primary,
                onChanged: (v) =>
                    ThemeService.instance.setLiquidGlassEnabled(v),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MatteGlassToggleRow extends StatelessWidget {
  const _MatteGlassToggleRow();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.matteGlassNotifier,
      builder: (context, enabled, _) {
        return GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Матовое стекло',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (ThemeService.instance.showDetailedDescriptions) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Дополнительный blur фона; можно включить вместе с рефракцией',
                        style: TextStyle(color: GE.sub, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              GhostSwitch(
                value: enabled,
                activeColor: GE.primary,
                onChanged: (v) => ThemeService.instance.setMatteGlassEnabled(v),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _GlassTintToggleRow extends StatelessWidget {
  const _GlassTintToggleRow();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.glassTintNotifier,
      builder: (context, enabled, _) {
        return GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Цветной фон стекла',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (ThemeService.instance.showDetailedDescriptions) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Тонированная заливка поверхности; выключено — прозрачная линза',
                        style: TextStyle(color: GE.sub, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              GhostSwitch(
                value: enabled,
                activeColor: GE.primary,
                onChanged: (v) => ThemeService.instance.setGlassTintEnabled(v),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Переключатель «Сияющий / Минимализм» — независимая от палитры ось стиля
/// отрисовки (см. ThemeStyle в theme_service.dart). Смена стиля сама
/// подбирает подходящего «близнеца» текущей палитры (ThemeService.setStyle),
/// поэтому здесь только два сегмента, без привязки к конкретной теме.
class _StyleSwitcher extends StatelessWidget {
  const _StyleSwitcher();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeStyle>(
      valueListenable: ThemeService.instance.styleNotifier,
      builder: (context, style, _) {
        final flat = ThemeService.isMinimal;
        Widget segment(String label, ThemeStyle value) {
          final active = style == value;
          return Expanded(
            child: GestureDetector(
              onTap: () => ThemeService.instance.setStyle(value),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active
                      ? GE.primary.withValues(alpha: 0.18)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(GE.radiusSm),
                  // Контур — только в "Классическом": минимализм отличает
                  // активный сегмент одной лишь заливкой, без обводки.
                  border: flat
                      ? null
                      : (active
                            ? Border.all(color: GE.primary, width: 1.5)
                            : Border.all(
                                color: Colors.transparent,
                                width: 1.5,
                              )),
                ),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? GE.primary : GE.sub,
                    // 4 сегмента в ряд (был 13 при 2-3) — иначе "Традиционный"
                    // не влезает на узких экранах.
                    fontSize: 11,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          );
        }

        return GlassCard(
          isListSection: true,
          padding: const EdgeInsets.all(6),
          child: Row(
            children: [
              segment('Классический', ThemeStyle.vivid),
              const SizedBox(width: 6),
              segment('Минимализм', ThemeStyle.minimal),
              const SizedBox(width: 6),
              segment('Монотон', ThemeStyle.mono),
              const SizedBox(width: 6),
              segment('Традиционный', ThemeStyle.traditional),
            ],
          ),
        );
      },
    );
  }
}

/// Вкл/выкл анимированный mesh-фон (точки+линии+свечение). Меш остаётся
/// фирменным дефолтом — тумблер только даёт возможность отключить его
/// ради минимализма, не меняя остальную палитру/тему.
class _MeshToggleRow extends StatelessWidget {
  const _MeshToggleRow();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.meshNotifier,
      builder: (context, enabled, _) {
        return GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Анимированный фон',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (ThemeService.instance.showDetailedDescriptions) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Точки, линии и свечение позади экранов',
                        style: TextStyle(color: GE.sub, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              GhostSwitch(
                value: enabled,
                activeColor: GE.primary,
                onChanged: (v) => ThemeService.instance.setMeshEnabled(v),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MeshSpeedRow extends StatelessWidget {
  const _MeshSpeedRow();

  String _label(double value) {
    if ((value - 1.0).abs() < 0.01) return 'Обычная';
    if (value < 1.0) return 'Медленно';
    return 'Быстро';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: ThemeService.instance.meshSpeedNotifier,
      builder: (context, speed, _) {
        return GlassCard(
          isListSection: true,
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Скорость mesh-фона',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    _label(speed),
                    style: TextStyle(color: GE.sub, fontSize: 12),
                  ),
                ],
              ),
              if (ThemeService.instance.showDetailedDescriptions)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Настройка скорости движения точек и линий',
                    style: TextStyle(color: GE.sub, fontSize: 11),
                  ),
                ),
              Slider(
                value: speed,
                min: 0.25,
                max: 2.0,
                divisions: 7,
                activeColor: GE.primary,
                inactiveColor: GE.border,
                label: '${speed.toStringAsFixed(2)}×',
                onChanged: (value) => ThemeService.instance.setMeshSpeed(value),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MeshTouchReactionRow extends StatelessWidget {
  const _MeshTouchReactionRow();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.meshTouchReactionNotifier,
      builder: (context, enabled, _) {
        return GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Реакция mesh-фона на касания',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (ThemeService.instance.showDetailedDescriptions) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Точки и линии реагируют на палец и курсор',
                        style: TextStyle(color: GE.sub, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              GhostSwitch(
                value: enabled,
                activeColor: GE.primary,
                onChanged: ThemeService.instance.setMeshTouchReaction,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PreciseMessageTimeRow extends StatelessWidget {
  const _PreciseMessageTimeRow();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.preciseMessageTimeNotifier,
      builder: (context, enabled, _) {
        return GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Точный таймер сообщений',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (ThemeService.instance.showDetailedDescriptions) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Показывать секунды рядом со временем сообщения',
                        style: TextStyle(color: GE.sub, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              GhostSwitch(
                value: enabled,
                activeColor: GE.primary,
                onChanged: ThemeService.instance.setPreciseMessageTime,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Тумблер "Фон списков" — карточки-обёртки списков (Настройки, Разрешения
/// при первом запуске) обычно рисуют сплошную заливку+блюр вокруг всего
/// списка. Выключено по умолчанию везде: остаются только разделительные
/// линии между строками, без плашки вокруг (см. GlassCard.isListSection).
/// Сама эта карточка — НЕ список (isListSection не ставим), чтобы тумблер
/// не пропадал вместе с тем, что он же выключает.
class _ListPlatesToggleRow extends StatelessWidget {
  const _ListPlatesToggleRow();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.listPlatesNotifier,
      builder: (context, enabled, _) {
        return GlassCard(
          ignoreSurfaceToggle: true,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Фон карточки',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (ThemeService.instance.showDetailedDescriptions) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Заливка вокруг карточек и списков по всему приложению',
                        style: TextStyle(color: GE.sub, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              GhostSwitch(
                value: enabled,
                activeColor: GE.primary,
                onChanged: (v) => ThemeService.instance.setListPlatesEnabled(v),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NavBarAppearanceControls extends StatelessWidget {
  const _NavBarAppearanceControls();

  @override
  Widget build(BuildContext context) {
    final settings = NavBarSettings.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([
        settings.backgroundNotifier,
        settings.labelsVisibleNotifier,
        settings.selectedBackgroundNotifier,
        settings.selectedScaleNotifier,
        settings.selectedFlyoutNotifier,
      ]),
      builder: (_, _) => Column(
        children: [
          _navBarToggle(
            title: 'Фон нижнего бара',
            description: 'Показывать подложку панели навигации',
            value: settings.backgroundNotifier.value,
            onChanged: settings.setBackgroundEnabled,
          ),
          _navBarToggle(
            title: 'Текст под иконками',
            description: 'Показывать подписи категорий',
            value: settings.labelsVisibleNotifier.value,
            onChanged: settings.setLabelsVisible,
          ),
          _navBarToggle(
            title: 'Фон выбранного',
            description: 'Подсвечивать активную категорию',
            value: settings.selectedBackgroundNotifier.value,
            onChanged: settings.setSelectedBackground,
          ),
          _navBarToggle(
            title: 'Увеличивать выбранное',
            description: 'Активная категория становится крупнее остальных',
            value: settings.selectedScaleNotifier.value,
            onChanged: settings.setSelectedScale,
          ),
          _navBarToggle(
            title: 'Вылет текста влево',
            description: 'Анимированно раскрывать подпись активной категории',
            value: settings.selectedFlyoutNotifier.value,
            onChanged: settings.setSelectedFlyout,
            last: true,
          ),
        ],
      ),
    );
  }

  Widget _navBarToggle({
    required String title,
    required String description,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool last = false,
  }) {
    return Column(
      children: [
        GlassCard(
          ignoreSurfaceToggle: true,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (ThemeService.instance.showDetailedDescriptions)
                      Text(
                        description,
                        style: TextStyle(color: GE.sub, fontSize: 11),
                      ),
                  ],
                ),
              ),
              GhostSwitch(
                value: value,
                activeColor: GE.primary,
                onChanged: onChanged,
              ),
            ],
          ),
        ),
        if (!last) const SizedBox(height: 8),
      ],
    );
  }
}

// Отдельный тумблер ТОЛЬКО для таблетки нижнего бара — не связан с
// _ListPlatesToggleRow выше (тот теперь управляет фоном везде ЕЩЁ, кроме бара).
class _NavBarPlateToggleRow extends StatelessWidget {
  const _NavBarPlateToggleRow();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.navBarPlateNotifier,
      builder: (context, enabled, _) {
        return GlassCard(
          ignoreSurfaceToggle: true,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Фон нижнего бара',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (ThemeService.instance.showDetailedDescriptions) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Заливка таблетки с Чаты/Профиль/Настройки — отдельно от остальных списков',
                        style: TextStyle(color: GE.sub, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              GhostSwitch(
                value: enabled,
                activeColor: GE.primary,
                onChanged: (v) =>
                    ThemeService.instance.setNavBarPlateEnabled(v),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Раздел: Разрешения ───────────────────────────────────────────────────────
class _PermissionsManageScreen extends StatefulWidget {
  const _PermissionsManageScreen();
  @override
  State<_PermissionsManageScreen> createState() =>
      _PermissionsManageScreenState();
}

class _PermissionsManageScreenState extends State<_PermissionsManageScreen>
    with WidgetsBindingObserver {
  Map<Permission, PermissionStatus> _st = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PermissionUsageAudit.instance.addListener(_onAuditChanged);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PermissionUsageAudit.instance.removeListener(_onAuditChanged);
    super.dispose();
  }

  void _onAuditChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    await PermissionUsageAudit.instance.load();
    final s = await checkAllPermissions();
    if (!mounted) return;
    setState(() {
      _st = s;
      _loading = false;
    });
  }

  Future<void> _toggle(Permission p, bool granted) async {
    if (granted) {
      await openAppSettings(); // отозвать можно только в системных настройках
    } else {
      final st = await p.status;
      if (st.isPermanentlyDenied) {
        await openAppSettings();
      } else {
        await p.request();
      }
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return _SectionScaffold(
      title: 'Разрешения',
      actions: [
        IconButton(
          icon: Icon(CupertinoIcons.settings, color: GE.sub),
          tooltip: 'Настройки приложения',
          onPressed: openAppSettings,
        ),
      ],
      children: _loading
          ? [
              const SizedBox(height: 8),
              GlassCard(
                isListSection: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: const SkeletonRowList(count: 4, avatarSize: 28),
              ),
            ]
          : [
              GlassCard(
                isListSection: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    for (int i = 0; i < appPermissions.length; i++) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              permIcon(appPermissions[i]),
                              size: 20,
                              color: GE.primary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    permLabel(appPermissions[i]),
                                    style: TextStyle(
                                      color: GE.text,
                                      fontSize: 14,
                                    ),
                                  ),
                                  Text(
                                    (_st[appPermissions[i]]?.isGranted ?? false)
                                        ? 'Разрешено'
                                        : 'Нет доступа',
                                    style: TextStyle(
                                      color:
                                          (_st[appPermissions[i]]?.isGranted ??
                                              false)
                                          ? GE.green
                                          : GE.sub,
                                      fontSize: 11,
                                    ),
                                  ),
                                  Text(
                                    permissionUsageLabel(
                                      PermissionUsageAudit.instance.lastFor(
                                        appPermissions[i],
                                      ),
                                    ),
                                    style: TextStyle(
                                      color: GE.sub,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            GhostSwitch(
                              value: _st[appPermissions[i]]?.isGranted ?? false,
                              activeColor: GE.primary,
                              onChanged: (v) => _toggle(
                                appPermissions[i],
                                _st[appPermissions[i]]?.isGranted ?? false,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (i != appPermissions.length - 1)
                        Divider(height: 1, color: GE.glassBorder, indent: 44),
                    ],
                  ],
                ),
              ),
              if (ThemeService.instance.showDetailedDescriptions)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Отозвать выданное разрешение можно только в системных '
                    'настройках — переключатель откроет их.',
                    style: TextStyle(color: GE.sub, fontSize: 11, height: 1.4),
                  ),
                ),
            ],
    );
  }
}

// ─── Раздел: Ключи шифрования ─────────────────────────────────────────────────
class _KeysScreen extends StatelessWidget {
  const _KeysScreen();

  void _toast(String m) => toast.show(m);

  Future<void> _cloudBackup(BuildContext context) async {
    final pwd = await _askPassword(context);
    if (pwd == null || pwd.isEmpty) return;
    _toast('Проверяю и сохраняю ключ…');
    final r = await ChatRepo.instance.changeKeyStorageMode(
      targetMode: 'server',
      password: pwd,
    );
    _toast(
      r == KeySyncOutcome.ok
          ? 'Серверная копия включена — ключ переживёт переустановку'
          : r == KeySyncOutcome.serverCopyMissing
          ? 'На сервере нет копии ключа'
          : 'Не вышло (проверь пароль)',
    );
  }

  Future<void> _restoreServer(BuildContext context) async {
    final pwd = await _askPassword(context);
    if (pwd == null || pwd.isEmpty) return;
    _toast('Расшифровываю серверную копию…');
    final r = await ChatRepo.instance.completeKeySetup(
      mode: 'server',
      createNew: false,
      password: pwd,
    );
    _toast(
      r == KeySyncOutcome.ok
          ? 'Ключ восстановлен и проверен'
          : r == KeySyncOutcome.serverCopyMissing
          ? 'На сервере нет зашифрованной копии ключа.'
          : r == KeySyncOutcome.keyMismatch
          ? 'Ключ не совпал с публичным ключом аккаунта.'
          : 'Не удалось расшифровать ключ. Проверь пароль.',
    );
  }

  Future<void> _changeStorage(BuildContext context) async {
    final target = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Где хранить ключ?', style: TextStyle(color: GE.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.phonelink_lock_outlined, color: GE.primary),
              title: Text(
                'Только на устройстве',
                style: TextStyle(color: GE.text),
              ),
              onTap: () => Navigator.pop(d, 'local'),
            ),
            ListTile(
              leading: Icon(Icons.cloud_done_outlined, color: GE.primary),
              title: Text('На сервере', style: TextStyle(color: GE.text)),
              onTap: () => Navigator.pop(d, 'server'),
            ),
          ],
        ),
      ),
    );
    if (target == null || !context.mounted) return;
    final pwd = await _askPassword(context);
    if (pwd == null || pwd.isEmpty) return;
    _toast('Меняю место хранения…');
    final r = await ChatRepo.instance.changeKeyStorageMode(
      targetMode: target,
      password: pwd,
    );
    _toast(
      r == KeySyncOutcome.ok
          ? 'Место хранения изменено'
          : 'Не удалось изменить место хранения. Ключ не удалён.',
    );
  }

  Future<String?> _askPassword(BuildContext context) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Пароль аккаунта', style: TextStyle(color: GE.text)),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          style: TextStyle(color: GE.text),
          decoration: InputDecoration(
            hintText: 'Пароль',
            hintStyle: TextStyle(color: GE.sub),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, ctrl.text),
            child: Text('Продолжить', style: TextStyle(color: GE.primary)),
          ),
        ],
      ),
    );
  }

  Future<void> _showSeed(BuildContext context) async {
    final m = await ChatRepo.instance.v2Mnemonic();
    if (!context.mounted) return;
    if (m == null || m.trim().isEmpty) {
      _toast('Seed ещё не создан (v2 не инициализирован)');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Seed-фраза v2', style: TextStyle(color: GE.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '12 слов — резервная копия v2-личности и привязка других устройств. Никому '
              'не показывай.',
              style: TextStyle(color: GE.sub, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: GE.glassFill,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: GE.borderStrong),
              ),
              child: SelectableText(
                m,
                style: TextStyle(
                  color: GE.text,
                  fontSize: 15,
                  height: 1.6,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: m));
              _toast('Скопировано');
            },
            child: Text('Копировать', style: TextStyle(color: GE.primary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: Text('Закрыть', style: TextStyle(color: GE.sub)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRegenerate(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Перегенерировать ключ?', style: TextStyle(color: GE.text)),
        content: Text(
          'Будет создан новый приватный ключ. Все ранее присланные сообщения, '
          'зашифрованные старым ключом, СТАНУТ нечитаемыми. Только если ничего '
          'не помогает.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text('Перегенерировать', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final prefs = await SharedPreferences.getInstance();
    final mode = (prefs.getString('key_storage_mode') ?? 'local').toLowerCase();
    String? password;
    if (mode == 'server') {
      password = await _askPassword(context);
      if (password == null || password.isEmpty) return;
    }
    _toast('Генерирую новый ключ…');
    _toast(await ChatRepo.instance.regenerateKeys(password: password));
  }

  @override
  Widget build(BuildContext context) {
    return _SectionScaffold(
      title: 'Ключи шифрования',
      children: [
        _sectionTitle('Резервная копия'),
        GlassCard(
          isListSection: true,
          child: Column(
            children: [
              _tile(
                CupertinoIcons.cloud_upload,
                'Зашифровать ключ на сервере',
                () => _cloudBackup(context),
                sub:
                    'Сначала спросит пароль; приватный ключ шифруется Argon2id и переживёт переустановку',
              ),
              _tile(
                CupertinoIcons.cloud_download,
                'Восстановить ключ с сервера',
                () => _restoreServer(context),
                sub:
                    'Повторно введи пароль — ключ проверяется по публичной части',
              ),
              _tile(
                CupertinoIcons.arrow_left_right,
                'Где хранить ключ',
                () => _changeStorage(context),
                sub: 'Переключение local/server с проверкой пароля',
              ),
              _tile(
                Icons.vpn_key_outlined,
                'Seed-фраза v2 (12 слов)',
                () => _showSeed(context),
                sub:
                    'Резервная копия v2-личности + привязка веба/других устройств',
                last: true,
              ),
            ],
          ),
        ),
        _sectionTitle('Обслуживание'),
        GlassCard(
          isListSection: true,
          child: Column(
            children: [
              _tile(
                CupertinoIcons.refresh,
                'Перегенерировать E2E-пару',
                () => _confirmRegenerate(context),
                sub: 'Новый приватный ключ: старую переписку не расшифровать',
                danger: true,
                last: true,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Раздел: О приложении ─────────────────────────────────────────────────────
class _AboutScreen extends StatefulWidget {
  const _AboutScreen();
  @override
  State<_AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<_AboutScreen> {
  String _version = '…';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _version = '${info.version}+${info.buildNumber}');
      }
    } catch (_) {
      if (mounted) setState(() => _version = '?');
    }
  }

  Future<void> _openChannel() async {
    if (!await PublicPageLink.open('https://t.me/waki_one')) {
      toast.show('Не удалось открыть ссылку');
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionScaffold(
      title: 'О приложении',
      children: [
        GlassCard(
          isListSection: true,
          child: Column(
            children: [
              _tile(
                CupertinoIcons.info_circle,
                'GhostChat · v$_version',
                () {
                  Clipboard.setData(ClipboardData(text: _version));
                  toast.show('Версия скопирована');
                },
                trailingIcon: CupertinoIcons.doc_on_doc,
              ),
              _tile(
                CupertinoIcons.smiley,
                'Эмодзи — Twemoji (CC BY 4.0)',
                null,
                sub: 'Графика эмодзи © Twitter/jdecked, CC BY 4.0',
              ),
              _tile(
                Icons.telegram,
                'Канал в Telegram',
                _openChannel,
                sub: '@waki_one',
                trailingIcon: CupertinoIcons.arrow_up_right_square,
              ),
              _tile(
                CupertinoIcons.question_circle,
                'Помощь',
                () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SupportScreen()),
                ),
                last: true,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Сетка тем ────────────────────────────────────────────────────────────────
class _ThemeGrid extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // Только «близнецы» текущего стиля (сияющий/минимализм) — остальные 6
    // скрыты, чтобы не путать плоскую тему с glass-темой одного цвета.
    final presets = ThemeService.instance.presetsForCurrentStyle;
    final current = ThemeService.instance.notifier.value;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.5,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: presets.length + 1,
      itemBuilder: (_, i) {
        // Без const — та же ловушка identical-виджета, что у _StyleSwitcher/
        // _MeshToggleRow: иначе "Новая тема" не подхватывает новый радиус.
        if (i == presets.length) return _CreateThemeCard();
        final p = presets[i];
        final active = p.id == current.id;
        final flat = p.style != ThemeStyle.vivid;
        return InkWell(
          borderRadius: BorderRadius.circular(GE.radiusMd),
          onTap: () => ThemeService.instance.setPreset(p.id),
          onLongPress: p.isCustom ? () => _openThemeMenu(context, p) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [p.bg, p.bgDeep],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(GE.radiusMd),
              // Минимализм: без контура и без свечения — выбранную тему
              // отличает только галочка (см. ниже), не рамка/glow.
              border: flat
                  ? null
                  // p.borderStrong (не хардкод white) — у каждого пресета свой
                  // адаптивный тон, иначе на светлой "Слоновой кости" рамка
                  // неактивной плитки была не видна на её же светлом фоне.
                  : Border.all(
                      color: active ? p.primary : p.borderStrong,
                      width: active ? 2 : 1,
                    ),
              // Тише, чем раньше (0.4/18) — плотное лёгкое свечение вместо
              // неонового ореола.
              boxShadow: (!flat && active)
                  ? [
                      BoxShadow(
                        color: p.primary.withValues(alpha: 0.22),
                        blurRadius: 10,
                      ),
                    ]
                  : null,
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [p.primary, p.primary2],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: p.green,
                      ),
                    ),
                    const Spacer(),
                    if (active)
                      Icon(
                        CupertinoIcons.checkmark_circle_fill,
                        color: p.primary,
                        size: 18,
                      ),
                  ],
                ),
                const Spacer(),
                Text(
                  p.name.isEmpty ? 'Без названия' : p.name,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (ThemeService.instance.showDetailedDescriptions)
                  Text(
                    p.isCustom ? 'Своя тема' : p.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.text.withValues(alpha: 0.65),
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openThemeMenu(BuildContext context, Palette p) async {
    // Navigator/ThemeService захватываем сразу — сетка тем перестраивается на
    // каждое действие (переименование/удаление меняют customPresetsNotifier),
    // и context этого builder-а не переживёт такую перестройку (тот же баг,
    // что был в _CreateThemeCard._create).
    final navigator = Navigator.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: GE.bgDeep,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: GE.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  p.name.isEmpty ? 'Без названия' : p.name,
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: Icon(CupertinoIcons.pencil, color: GE.text),
              title: Text('Редактировать', style: TextStyle(color: GE.text)),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: Icon(CupertinoIcons.square_pencil, color: GE.text),
              title: Text('Переименовать', style: TextStyle(color: GE.text)),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: Icon(CupertinoIcons.doc_on_doc, color: GE.text),
              title: Text('Дублировать', style: TextStyle(color: GE.text)),
              onTap: () => Navigator.pop(ctx, 'duplicate'),
            ),
            ListTile(
              leading: Icon(
                CupertinoIcons.arrow_right_arrow_left,
                color: GE.text,
              ),
              title: Text(
                'Перенести палитру из другой темы',
                style: TextStyle(color: GE.text),
              ),
              onTap: () => Navigator.pop(ctx, 'transfer'),
            ),
            ListTile(
              leading: Icon(CupertinoIcons.trash, color: GE.red),
              title: Text('Удалить', style: TextStyle(color: GE.red)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    switch (action) {
      case 'edit':
        await ThemeService.instance.openCustomThemeForEdit(p.id);
        navigator.push(
          MaterialPageRoute(builder: (_) => CustomThemeScreen(themeId: p.id)),
        );
        break;
      case 'rename':
        await _renameTheme(navigator, p);
        break;
      case 'duplicate':
        final dup = await ThemeService.instance.duplicateCustomTheme(p.id);
        if (dup == null) {
          toast.show('Своих тем уже 100 — сначала удалите ненужные');
        } else {
          toast.show('Тема продублирована');
        }
        break;
      case 'delete':
        await _deleteTheme(navigator, p);
        break;
      case 'transfer':
        if (!navigator.mounted) return;
        final sourceId = await pickSourceCustomTheme(
          navigator.context,
          excludeId: p.id,
        );
        if (sourceId == null) return;
        await ThemeService.instance.transferPaletteTo(
          fromId: sourceId,
          toId: p.id,
        );
        toast.show('Палитра перенесена');
        break;
    }
  }

  Future<void> _renameTheme(NavigatorState navigator, Palette p) async {
    final ctrl = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: navigator.context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Название темы', style: TextStyle(color: GE.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 40,
          style: TextStyle(color: GE.text),
          decoration: InputDecoration(hintText: 'Например, «Мой закат»'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(
              'Готово',
              style: TextStyle(color: GE.primary, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    if (name == null) return;
    await ThemeService.instance.renameCustomTheme(p.id, name);
  }

  Future<void> _deleteTheme(NavigatorState navigator, Palette p) async {
    final confirmed = await showDialog<bool>(
      context: navigator.context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Удалить тему?', style: TextStyle(color: GE.text)),
        content: Text(
          '«${p.name.isEmpty ? 'Без названия' : p.name}» будет удалена без возможности восстановить.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Удалить',
              style: TextStyle(color: GE.red, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final wasActive = ThemeService.instance.notifier.value.id == p.id;
    if (wasActive) {
      if (!navigator.mounted) return;
      // Удаляем активную тему — спрашиваем, на какую переключиться, вместо
      // молчаливого отката на дефолтный встроенный пресет.
      final replacementId = await _pickReplacementTheme(
        navigator.context,
        excludeId: p.id,
      );
      if (replacementId == null) return; // передумали — тема не удаляется
      await ThemeService.instance.setPreset(replacementId);
    }
    await ThemeService.instance.deleteCustomTheme(p.id);
  }
}

/// Показывает лист выбора темы (встроенные + свои, кроме excludeId) — на что
/// переключиться, если удаляется активная своя тема.
Future<String?> _pickReplacementTheme(
  BuildContext context, {
  required String excludeId,
}) {
  final builtins = ThemeService.instance.presets.where(
    (p) => p.style == ThemeService.instance.styleNotifier.value,
  );
  final customs = ThemeService.instance.customPresets.where(
    (p) => p.id != excludeId,
  );
  final options = [...builtins, ...customs];
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: GE.bgDeep,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: GE.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'На какую тему переключиться?',
                style: TextStyle(
                  color: GE.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final opt in options)
                  ListTile(
                    leading: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [opt.primary, opt.primary2],
                        ),
                      ),
                    ),
                    title: Text(
                      opt.name.isEmpty ? 'Без названия' : opt.name,
                      style: TextStyle(color: GE.text),
                    ),
                    subtitle: opt.isCustom
                        ? Text(
                            'Своя тема',
                            style: TextStyle(color: GE.sub, fontSize: 11),
                          )
                        : null,
                    onTap: () => Navigator.pop(ctx, opt.id),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Показывает лист выбора одной из СВОИХ тем (кроме excludeId) — источник для
/// "перенести палитру"/"перенести цвет поверхности". Возвращает выбранный id
/// или null, если отменили (или своих тем-доноров просто нет).
Future<String?> pickSourceCustomTheme(
  BuildContext context, {
  required String excludeId,
}) async {
  final options = ThemeService.instance.customPresets
      .where((p) => p.id != excludeId)
      .toList();
  if (options.isEmpty) {
    toast.show('Нет других своих тем, откуда переносить');
    return null;
  }
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: GE.bgDeep,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: GE.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Взять из какой темы?',
                style: TextStyle(
                  color: GE.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final src in options)
                  ListTile(
                    leading: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [src.primary, src.primary2],
                        ),
                      ),
                    ),
                    title: Text(
                      src.name.isEmpty ? 'Без названия' : src.name,
                      style: TextStyle(color: GE.text),
                    ),
                    onTap: () => Navigator.pop(ctx, src.id),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Слайдер глобального скругления углов — от острых (90°) до максимально
/// круглых (45°), метка-градус сидит у самого угла превью-квадрата. Двигает
/// живьём: ThemeService.setCornerFactor триггерит cornerNotifier, все
/// GE.radiusSm/Md/Lg пересчитываются геттерами — эффект виден по всему
/// приложению сразу, не только в этом превью.
class _ProfileMusicWidgetStyleRow extends StatelessWidget {
  const _ProfileMusicWidgetStyleRow();

  @override
  Widget build(BuildContext context) {
    final settings = ProfileAppearanceSettings.instance;
    return ValueListenableBuilder<ProfileMusicWidgetStyle>(
      valueListenable: settings.musicWidgetStyleNotifier,
      builder: (context, selected, _) => GlassCard(
        isListSection: true,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Виджет музыки',
              style: TextStyle(
                color: GE.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (ThemeService.instance.showDetailedDescriptions) ...[
              const SizedBox(height: 3),
              Text(
                'Выбери большую карточку или компактную строку под шапкой профиля.',
                style: TextStyle(color: GE.sub, fontSize: 11.5),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _styleButton(
                    icon: CupertinoIcons.rectangle,
                    label: 'Карточка',
                    selected: selected == ProfileMusicWidgetStyle.card,
                    onTap: () => settings.setMusicWidgetStyle(
                      ProfileMusicWidgetStyle.card,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _styleButton(
                    icon: CupertinoIcons.music_note_2,
                    label: 'Минималистичный',
                    selected: selected == ProfileMusicWidgetStyle.pill,
                    onTap: () => settings.setMusicWidgetStyle(
                      ProfileMusicWidgetStyle.pill,
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

  Widget _styleButton({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? GE.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(GE.radiusSm),
          border: Border.all(
            color: selected ? GE.primary : GE.glassBorder,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: selected ? GE.primary : GE.sub),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: selected ? GE.primary : GE.sub,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioPlayerAppearanceControls extends StatelessWidget {
  const _AudioPlayerAppearanceControls();

  @override
  Widget build(BuildContext context) {
    final player = GlobalAudioPlayer.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([player, player.positionNotifier]),
      builder: (context, _) => GlassCard(
        isListSection: true,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Поверхность',
              style: TextStyle(
                color: GE.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              'Плеер использует матовое стекло: заливка + blur. Долгое нажатие на сам плеер меняет его сторону и сохраняет выбор.',
              style: TextStyle(color: GE.sub, fontSize: 11.5, height: 1.3),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _playerStyleButton(
                    player,
                    AudioPlayerVisualStyle.matte,
                    CupertinoIcons.rectangle,
                    'Матовое',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _playerStyleButton(
                    player,
                    AudioPlayerVisualStyle.compact,
                    CupertinoIcons.rectangle_compress_vertical,
                    'Компактное',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'Положение по умолчанию',
              style: TextStyle(
                color: GE.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _playerPositionButton(
                    player,
                    AudioPlayerPosition.top,
                    CupertinoIcons.arrow_up,
                    'Сверху',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _playerPositionButton(
                    player,
                    AudioPlayerPosition.bottom,
                    CupertinoIcons.arrow_down,
                    'Снизу',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _playerStyleButton(
    GlobalAudioPlayer player,
    AudioPlayerVisualStyle value,
    IconData icon,
    String label,
  ) {
    final selected = player.visualStyle == value;
    return _playerChoice(
      icon: icon,
      label: label,
      selected: selected,
      onTap: () => player.setVisualStyle(value),
    );
  }

  Widget _playerPositionButton(
    GlobalAudioPlayer player,
    AudioPlayerPosition value,
    IconData icon,
    String label,
  ) {
    final selected = player.positionNotifier.value == value;
    return _playerChoice(
      icon: icon,
      label: label,
      selected: selected,
      onTap: () => player.setPosition(value),
    );
  }

  Widget _playerChoice({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? GE.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(GE.radiusSm),
          border: Border.all(
            color: selected ? GE.primary : GE.glassBorder,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: selected ? GE.primary : GE.sub),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? GE.primary : GE.sub,
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AvatarBannerBufferSlider extends StatelessWidget {
  const _AvatarBannerBufferSlider();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: ThemeService.instance.avatarBannerBufferNotifier,
      builder: (context, buffer, _) => GlassCard(
        isListSection: true,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Размер буфера',
                    style: TextStyle(
                      color: GE.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${buffer.round()} px',
                  style: TextStyle(
                    color: GE.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Slider(
              value: buffer,
              min: 0,
              max: 40,
              divisions: 40,
              activeColor: GE.primary,
              inactiveColor: GE.sub.withValues(alpha: 0.35),
              onChanged: ThemeService.instance.setAvatarBannerBuffer,
            ),
            if (ThemeService.instance.showDetailedDescriptions)
              Text(
                'Нейтральная зона между баннером и аватаркой. Меняет профиль и превью в настройках одновременно.',
                style: TextStyle(color: GE.sub, fontSize: 12, height: 1.35),
              ),
          ],
        ),
      ),
    );
  }
}

class _CornerRadiusSlider extends StatelessWidget {
  const _CornerRadiusSlider();

  @override
  Widget build(BuildContext context) {
    // Слушаем cornerNotifier напрямую — раньше слайдер кэшировал значение в
    // локальном State один раз при создании и не замечал внешние правки
    // (напр. автоматическое скругление 45° при входе в монотон, см.
    // ThemeService.setStyle): цифра "68°" зависала на экране, хотя реальное
    // скругление уже сменилось.
    return ValueListenableBuilder<double>(
      valueListenable: ThemeService.instance.cornerNotifier,
      builder: (context, factor, _) => _buildCard(context, factor),
    );
  }

  void _onChanged(double v) {
    ThemeService.instance.setCornerFactor(v);
  }

  Widget _buildCard(BuildContext context, double factor) {
    final degrees = (90 - 45 * factor).round();
    final previewRadius = (10 + 38 * factor).clamp(0.0, 48.0);
    return GlassCard(
      isListSection: true,
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          SizedBox(
            height: 100,
            child: Center(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [GE.primary2, GE.primary],
                      ),
                      borderRadius: BorderRadius.circular(previewRadius),
                    ),
                  ),
                  Positioned(
                    left: -8,
                    top: -8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: GE.bgDeep,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '$degrees°',
                        style: TextStyle(
                          color: GE.text,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Row(
            children: [
              Text('Острые', style: TextStyle(color: GE.sub, fontSize: 11)),
              Expanded(
                child: Slider(
                  value: factor,
                  onChanged: _onChanged,
                  activeColor: GE.primary,
                  // Явный inactiveColor — иначе Slider берёт цвет трека из
                  // ColorScheme темы, который на части палитр почти совпадает
                  // с фоном карточки (трек "сливается" при смене темы).
                  inactiveColor: GE.sub.withValues(alpha: 0.35),
                ),
              ),
              Text('Круглые', style: TextStyle(color: GE.sub, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Заглушка "своя тема" — пока не функциональна (только визуальный стаб),
/// нажатие даёт понять, что фича готовится, а не молчит без реакции.
class _CreateThemeCard extends StatelessWidget {
  const _CreateThemeCard();

  Future<void> _create(BuildContext context) async {
    // Navigator захватываем ДО await: createDraftCustomTheme() синхронно
    // обновляет customPresetsNotifier, сетка тем перестраивается прямо во
    // время этого вызова и может пересоздать элемент этой карточки — тогда
    // просто `context` (и context.mounted) станет ложно "размонтированным",
    // и переход в редактор молча не произойдёт, хотя тема уже создана.
    // NavigatorState принадлежит стабильному предку выше по дереву, поэтому
    // его можно смело брать один раз в начале и использовать после await.
    final navigator = Navigator.of(context);
    final draft = await ThemeService.instance.createDraftCustomTheme();
    if (draft == null) {
      toast.show('Своих тем уже 100 — сначала удалите ненужные');
      return;
    }
    navigator.push(
      MaterialPageRoute(builder: (_) => CustomThemeScreen(themeId: draft.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(GE.radiusMd),
      onTap: () => _create(context),
      child: DottedBorderBox(
        radius: GE.radiusMd,
        color: GE.sub.withValues(alpha: 0.4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(CupertinoIcons.add, color: GE.sub, size: 26),
            const SizedBox(height: 6),
            Text(
              'Новая тема',
              style: TextStyle(
                color: GE.sub,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
