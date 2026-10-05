import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ChatHeaderTitleMode { displayName, username, chats, ghostChat }

extension ChatHeaderTitleModeText on ChatHeaderTitleMode {
  String get storageKey => switch (this) {
    ChatHeaderTitleMode.displayName => 'display_name',
    ChatHeaderTitleMode.username => 'username',
    ChatHeaderTitleMode.chats => 'chats',
    ChatHeaderTitleMode.ghostChat => 'ghost_chat',
  };

  String get label => switch (this) {
    ChatHeaderTitleMode.displayName => 'Имя',
    ChatHeaderTitleMode.username => 'Юзернейм',
    ChatHeaderTitleMode.chats => 'Чаты',
    ChatHeaderTitleMode.ghostChat => 'GhostChat',
  };

  String get description => switch (this) {
    ChatHeaderTitleMode.displayName => 'Отображаемое имя профиля',
    ChatHeaderTitleMode.username => 'Имя пользователя с @',
    ChatHeaderTitleMode.chats => 'Стандартный текст вкладки',
    ChatHeaderTitleMode.ghostChat => 'Название приложения',
  };
}

ChatHeaderTitleMode chatHeaderTitleModeFromStorage(String? value) {
  for (final mode in ChatHeaderTitleMode.values) {
    if (mode.storageKey == value) return mode;
  }
  return ChatHeaderTitleMode.displayName;
}

class ChatHeaderSettings {
  ChatHeaderSettings._();
  static final ChatHeaderSettings instance = ChatHeaderSettings._();

  static const _key = 'chat_header_title_mode_v1';

  final ValueNotifier<ChatHeaderTitleMode> modeNotifier = ValueNotifier(
    ChatHeaderTitleMode.displayName,
  );
  Future<void>? _loadFuture;

  Future<void> load() => _loadFuture ??= _loadFromPrefs();

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    modeNotifier.value = chatHeaderTitleModeFromStorage(prefs.getString(_key));
  }

  Future<void> setMode(ChatHeaderTitleMode mode) async {
    modeNotifier.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.storageKey);
  }
}
