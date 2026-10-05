import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local per-dialog flags shared by server, LAN and bookmark dialogs.
///
/// Dialogs are backed by three different stores, so putting these flags in a
/// single small preferences store keeps list behaviour identical everywhere.
class DialogSettingsStore {
  DialogSettingsStore._();
  static final DialogSettingsStore instance = DialogSettingsStore._();

  static const _key = 'dialog_settings_v1';
  final ValueNotifier<int> revision = ValueNotifier(0);
  final Set<String> _pinned = <String>{};
  final Set<String> _blocked = <String>{};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw);
      if (data is! Map) return;
      _pinned.addAll((data['pinned'] as List? ?? const []).whereType<String>());
      _blocked.addAll(
        (data['blocked'] as List? ?? const []).whereType<String>(),
      );
      revision.value++;
    } catch (_) {
      // Corrupt optional preferences must never prevent the chat list opening.
    }
  }

  bool isPinned(String dialogId) => _pinned.contains(dialogId);
  bool isBlocked(String dialogId) => _blocked.contains(dialogId);

  Future<void> setPinned(String dialogId, bool value) async {
    if (value) {
      _pinned.add(dialogId);
    } else {
      _pinned.remove(dialogId);
    }
    revision.value++;
    await _save();
  }

  Future<void> setBlocked(String dialogId, bool value) async {
    if (value) {
      _blocked.add(dialogId);
    } else {
      _blocked.remove(dialogId);
    }
    revision.value++;
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(<String, Object>{
        'pinned': _pinned.toList(),
        'blocked': _blocked.toList(),
      }),
    );
  }
}
