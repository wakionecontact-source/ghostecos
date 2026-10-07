import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

enum ChatMode { server, byok, work }

class SettingsService {
  static final SettingsService instance = SettingsService._();
  SettingsService._();
  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  ChatMode get mode {
    final v = _prefs?.getString('gg_mode') ?? 'chat';
    if (v == 'work') return ChatMode.work;
    if (v == 'byok') return ChatMode.byok;
    return ChatMode.server; // old `chat` and `server` values both meant server chat
  }
  Future<void> setMode(ChatMode m) async {
    final v = switch (m) {
      ChatMode.server => 'server',
      ChatMode.byok => 'byok',
      ChatMode.work => 'work',
    };
    await _prefs?.setString('gg_mode', v);
  }

  String get serverModel => _prefs?.getString('gg_server_model') ?? 'groq:gpt-oss-20b';
  Future<void> setServerModel(String k) async => _prefs?.setString('gg_server_model', k);
  String get chatModel => serverModel;
  Future<void> setChatModel(String k) async => setServerModel(k);

  String get gsToken => _prefs?.getString('gg_gs_token') ?? '';
  Future<void> setGsToken(String t) async => _prefs?.setString('gg_gs_token', t);

  Future<String?> getKey(String provider) async {
    final raw = _prefs?.getString('byok_$provider');
    if (raw==null) return null;
    try { return utf8.decode(base64Decode(raw)); } catch (_) { return raw; }
  }
  Future<void> setKey(String provider, String key) async {
    if (key.trim().isEmpty) {
      await _prefs?.remove('byok_$provider');
    } else {
      await _prefs?.setString('byok_$provider', base64Encode(utf8.encode(key.trim())));
    }
  }
  Future<void> deleteKey(String provider) async => _prefs?.remove('byok_$provider');
  Future<Map<String, String>> getAllKeys() async {
    final providers = ['groq','mistral','openrouter','sambanova','bazaarlink','zveno','freeai'];
    final map = <String,String>{};
    for (final p in providers) {
      final k = await getKey(p);
      if (k != null && k.isNotEmpty) map[p]=k;
    }
    return map;
  }

  String get byokModel => _prefs?.getString('gg_byok_model') ?? 'groq:gpt-oss-20b';
  Future<void> setByokModel(String k) async => _prefs?.setString('gg_byok_model', k);
  String get workModel => _prefs?.getString('gg_work_model') ?? 'pollinations:gpt-5-mini';
  Future<void> setWorkModel(String k) async => _prefs?.setString('gg_work_model', k);

  String get customPrompt => _prefs?.getString('gg_custom_prompt') ?? '';
  Future<void> setCustomPrompt(String v) async => _prefs?.setString('gg_custom_prompt', v);

  String get currentModel {
    if (mode == ChatMode.work) return workModel;
    if (mode == ChatMode.byok) return byokModel;
    return serverModel;
  }
  Future<void> setCurrentModel(String k) async {
    if (mode == ChatMode.work) await setWorkModel(k);
    else if (mode == ChatMode.byok) await setByokModel(k);
    else await setServerModel(k);
  }

  String get workDir => _prefs?.getString('work_dir') ?? '';
  Future<void> setWorkDir(String v) async => _prefs?.setString('work_dir', v);
  bool get workConfirmWrites => _prefs?.getBool('work_confirm_writes') ?? false;
  Future<void> setWorkConfirmWrites(bool v) async => _prefs?.setBool('work_confirm_writes', v);
}
