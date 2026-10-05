import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/local/app_logger.dart';
import 'api_client.dart';

enum PrivacyAudience { all, contacts, nobody }

extension PrivacyAudienceX on PrivacyAudience {
  String get value => name;

  String get label => switch (this) {
    PrivacyAudience.all => 'Все',
    PrivacyAudience.contacts => 'Контакты',
    PrivacyAudience.nobody => 'Никто',
  };

  static PrivacyAudience fromValue(Object? raw) => switch (raw?.toString()) {
    'contacts' => PrivacyAudience.contacts,
    'nobody' => PrivacyAudience.nobody,
    _ => PrivacyAudience.all,
  };
}

/// Account-scoped privacy preferences used by both the settings UI and chat.
///
/// The local value is applied immediately so opening the app does not depend on
/// the network. The server copy is refreshed in the background and is the
/// source of truth for visibility/read-receipt enforcement on other devices.
class PrivacySettings {
  PrivacySettings._();

  static final PrivacySettings instance = PrivacySettings._();

  static const _showOnlineField = 'show_online';
  static const _readReceiptsField = 'send_read_receipts';
  static const _allowChannelAddField = 'allow_channel_add';
  static const _allowGroupAddField = 'allow_group_add';
  static const _messagePrivacyField = 'message_privacy';
  static const _usernameVisibilityField = 'username_visibility';
  static const _displayNameVisibilityField = 'display_name_visibility';
  static const _avatarVisibilityField = 'avatar_visibility';
  static const _bannerVisibilityField = 'banner_visibility';
  static const _aboutVisibilityField = 'about_visibility';
  static const _musicVisibilityField = 'music_visibility';
  static const _callPrivacyField = 'call_privacy';

  final ValueNotifier<bool> showOnlineNotifier = ValueNotifier(true);
  final ValueNotifier<bool> readReceiptsNotifier = ValueNotifier(true);
  final ValueNotifier<bool> allowChannelAddNotifier = ValueNotifier(true);
  final ValueNotifier<bool> allowGroupAddNotifier = ValueNotifier(true);
  final ValueNotifier<PrivacyAudience> messagePrivacyNotifier = ValueNotifier(
    PrivacyAudience.all,
  );
  final ValueNotifier<PrivacyAudience> usernameVisibilityNotifier =
      ValueNotifier(PrivacyAudience.all);
  final ValueNotifier<PrivacyAudience> displayNameVisibilityNotifier =
      ValueNotifier(PrivacyAudience.all);
  final ValueNotifier<PrivacyAudience> avatarVisibilityNotifier = ValueNotifier(
    PrivacyAudience.all,
  );
  final ValueNotifier<PrivacyAudience> bannerVisibilityNotifier = ValueNotifier(
    PrivacyAudience.all,
  );
  final ValueNotifier<PrivacyAudience> aboutVisibilityNotifier = ValueNotifier(
    PrivacyAudience.all,
  );
  final ValueNotifier<PrivacyAudience> musicVisibilityNotifier = ValueNotifier(
    PrivacyAudience.all,
  );
  final ValueNotifier<PrivacyAudience> callPrivacyNotifier = ValueNotifier(
    PrivacyAudience.contacts,
  );

  final _api = ApiClient();
  String? _account;
  int _accountGeneration = 0;
  int _changeGeneration = 0;

  bool get showOnline => showOnlineNotifier.value;
  bool get sendReadReceipts => readReceiptsNotifier.value;

  String _normalizeAccount(String username) => username.trim().toLowerCase();

  String _prefKey(String account, String field) => 'privacy_${field}_$account';

  /// Loads the cached values and starts a non-blocking server refresh.
  Future<void> loadForAccount(String username) async {
    final account = _normalizeAccount(username);
    final generation = ++_accountGeneration;
    _account = account;
    _changeGeneration = 0;

    final prefs = await SharedPreferences.getInstance();
    if (generation != _accountGeneration || _account != account) return;
    showOnlineNotifier.value =
        prefs.getBool(_prefKey(account, _showOnlineField)) ?? true;
    readReceiptsNotifier.value =
        prefs.getBool(_prefKey(account, _readReceiptsField)) ?? true;
    allowChannelAddNotifier.value =
        prefs.getBool(_prefKey(account, _allowChannelAddField)) ?? true;
    allowGroupAddNotifier.value =
        prefs.getBool(_prefKey(account, _allowGroupAddField)) ?? true;
    messagePrivacyNotifier.value = PrivacyAudienceX.fromValue(
      prefs.getString(_prefKey(account, _messagePrivacyField)),
    );
    usernameVisibilityNotifier.value = PrivacyAudienceX.fromValue(
      prefs.getString(_prefKey(account, _usernameVisibilityField)),
    );
    displayNameVisibilityNotifier.value = PrivacyAudienceX.fromValue(
      prefs.getString(_prefKey(account, _displayNameVisibilityField)),
    );
    avatarVisibilityNotifier.value = PrivacyAudienceX.fromValue(
      prefs.getString(_prefKey(account, _avatarVisibilityField)),
    );
    bannerVisibilityNotifier.value = PrivacyAudienceX.fromValue(
      prefs.getString(_prefKey(account, _bannerVisibilityField)),
    );
    aboutVisibilityNotifier.value = PrivacyAudienceX.fromValue(
      prefs.getString(_prefKey(account, _aboutVisibilityField)),
    );
    musicVisibilityNotifier.value = PrivacyAudienceX.fromValue(
      prefs.getString(_prefKey(account, _musicVisibilityField)),
    );
    callPrivacyNotifier.value = PrivacyAudienceX.fromValue(
      prefs.getString(_prefKey(account, _callPrivacyField)) ?? 'contacts',
    );

    if (account == 'guest') return;

    final changeGeneration = _changeGeneration;
    unawaited(
      _refreshFromServer(
        account,
        accountGeneration: generation,
        changeGeneration: changeGeneration,
      ),
    );
  }

  Future<void> _refreshFromServer(
    String account, {
    required int accountGeneration,
    required int changeGeneration,
  }) async {
    try {
      final result = await _api.chatGet('/privacy');
      if (accountGeneration != _accountGeneration ||
          changeGeneration != _changeGeneration ||
          _account != account ||
          result is! Map) {
        return;
      }

      final showOnline = result['show_online'];
      final readReceipts = result['send_read_receipts'];
      if (showOnline is! bool || readReceipts is! bool) return;

      showOnlineNotifier.value = showOnline;
      readReceiptsNotifier.value = readReceipts;
      allowChannelAddNotifier.value = result['allow_channel_add'] != false;
      allowGroupAddNotifier.value = result['allow_group_add'] != false;
      messagePrivacyNotifier.value = PrivacyAudienceX.fromValue(
        result['message_privacy'],
      );
      usernameVisibilityNotifier.value = PrivacyAudienceX.fromValue(
        result['username_visibility'],
      );
      displayNameVisibilityNotifier.value = PrivacyAudienceX.fromValue(
        result['display_name_visibility'],
      );
      avatarVisibilityNotifier.value = PrivacyAudienceX.fromValue(
        result['avatar_visibility'],
      );
      bannerVisibilityNotifier.value = PrivacyAudienceX.fromValue(
        result['banner_visibility'],
      );
      aboutVisibilityNotifier.value = PrivacyAudienceX.fromValue(
        result['about_visibility'],
      );
      musicVisibilityNotifier.value = PrivacyAudienceX.fromValue(
        result['music_visibility'],
      );
      callPrivacyNotifier.value = PrivacyAudienceX.fromValue(
        result['call_privacy'] ?? 'contacts',
      );
      final prefs = await SharedPreferences.getInstance();
      if (accountGeneration != _accountGeneration ||
          changeGeneration != _changeGeneration ||
          _account != account) {
        return;
      }
      await prefs.setBool(_prefKey(account, _showOnlineField), showOnline);
      await prefs.setBool(_prefKey(account, _readReceiptsField), readReceipts);
      await prefs.setBool(
        _prefKey(account, _allowChannelAddField),
        allowChannelAddNotifier.value,
      );
      await prefs.setBool(
        _prefKey(account, _allowGroupAddField),
        allowGroupAddNotifier.value,
      );
      for (final entry in {
        _messagePrivacyField: messagePrivacyNotifier.value,
        _usernameVisibilityField: usernameVisibilityNotifier.value,
        _displayNameVisibilityField: displayNameVisibilityNotifier.value,
        _avatarVisibilityField: avatarVisibilityNotifier.value,
        _bannerVisibilityField: bannerVisibilityNotifier.value,
        _aboutVisibilityField: aboutVisibilityNotifier.value,
        _musicVisibilityField: musicVisibilityNotifier.value,
        _callPrivacyField: callPrivacyNotifier.value,
      }.entries) {
        await prefs.setString(_prefKey(account, entry.key), entry.value.value);
      }
    } catch (e) {
      // Offline startup is expected; the cached value remains active.
      appLog.debug('privacy', 'server privacy refresh skipped: $e');
    }
  }

  Future<void> setShowOnline(bool value) async {
    showOnlineNotifier.value = value;
    await _persistAndSync(
      field: _showOnlineField,
      value: value,
      body: {'show_online': value},
    );
  }

  Future<void> setSendReadReceipts(bool value) async {
    readReceiptsNotifier.value = value;
    await _persistAndSync(
      field: _readReceiptsField,
      value: value,
      body: {'send_read_receipts': value},
    );
  }

  Future<void> setAllowChannelAdd(bool value) async {
    allowChannelAddNotifier.value = value;
    await _persistAndSync(
      field: _allowChannelAddField,
      value: value,
      body: {'allow_channel_add': value},
    );
  }

  Future<void> setAllowGroupAdd(bool value) async {
    allowGroupAddNotifier.value = value;
    await _persistAndSync(
      field: _allowGroupAddField,
      value: value,
      body: {'allow_group_add': value},
    );
  }

  Future<void> setMessagePrivacy(PrivacyAudience value) =>
      _setAudience(_messagePrivacyField, messagePrivacyNotifier, value);

  Future<void> setUsernameVisibility(PrivacyAudience value) =>
      _setAudience(_usernameVisibilityField, usernameVisibilityNotifier, value);

  Future<void> setDisplayNameVisibility(PrivacyAudience value) => _setAudience(
    _displayNameVisibilityField,
    displayNameVisibilityNotifier,
    value,
  );

  Future<void> setAvatarVisibility(PrivacyAudience value) =>
      _setAudience(_avatarVisibilityField, avatarVisibilityNotifier, value);

  Future<void> setBannerVisibility(PrivacyAudience value) =>
      _setAudience(_bannerVisibilityField, bannerVisibilityNotifier, value);

  Future<void> setAboutVisibility(PrivacyAudience value) =>
      _setAudience(_aboutVisibilityField, aboutVisibilityNotifier, value);

  Future<void> setMusicVisibility(PrivacyAudience value) =>
      _setAudience(_musicVisibilityField, musicVisibilityNotifier, value);

  Future<void> setCallPrivacy(PrivacyAudience value) =>
      _setAudience(_callPrivacyField, callPrivacyNotifier, value);

  Future<void> _setAudience(
    String field,
    ValueNotifier<PrivacyAudience> notifier,
    PrivacyAudience value,
  ) async {
    notifier.value = value;
    await _persistAndSyncChoice(field: field, value: value);
  }

  Future<void> _persistAndSyncChoice({
    required String field,
    required PrivacyAudience value,
  }) async {
    final account = _account;
    ++_changeGeneration;
    if (account == null || account == 'guest') return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (account != _account) return;
      await prefs.setString(_prefKey(account, field), value.value);
      if (account != _account) return;
      await _api.chatPost('/privacy', {field: value.value});
    } catch (e) {
      appLog.warn('privacy', 'server privacy save failed: $e');
    }
  }

  Future<void> _persistAndSync({
    required String field,
    required bool value,
    required Map<String, dynamic> body,
  }) async {
    final account = _account;
    ++_changeGeneration;
    if (account == null || account == 'guest') return;

    try {
      final prefs = await SharedPreferences.getInstance();
      if (account != _account) return;
      await prefs.setBool(_prefKey(account, field), value);
    } catch (e) {
      appLog.warn('privacy', 'local privacy save failed: $e');
    }

    // Do not let a delayed write from the previous account use the new
    // account's Authorization header after logout/login.
    if (account != _account) return;

    try {
      await _api.chatPost('/privacy', body);
    } catch (e) {
      // Keep the optimistic local setting. A later refresh/retry can reconcile
      // it with the server without blocking the settings screen.
      appLog.warn('privacy', 'server privacy save failed: $e');
    }
  }

  void reset() {
    ++_accountGeneration;
    ++_changeGeneration;
    _account = null;
    showOnlineNotifier.value = true;
    readReceiptsNotifier.value = true;
    allowChannelAddNotifier.value = true;
    allowGroupAddNotifier.value = true;
    messagePrivacyNotifier.value = PrivacyAudience.all;
    usernameVisibilityNotifier.value = PrivacyAudience.all;
    displayNameVisibilityNotifier.value = PrivacyAudience.all;
    avatarVisibilityNotifier.value = PrivacyAudience.all;
    bannerVisibilityNotifier.value = PrivacyAudience.all;
    aboutVisibilityNotifier.value = PrivacyAudience.all;
    musicVisibilityNotifier.value = PrivacyAudience.all;
    callPrivacyNotifier.value = PrivacyAudience.contacts;
  }
}
