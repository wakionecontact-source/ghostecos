/// Рантайм GhostUI: встроенные конфиги, скачанные из GhostGallery, откат на
/// дефолт при ошибке.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_config.dart';

class UiExtensionInfo {
  const UiExtensionInfo({
    required this.id,
    required this.name,
    required this.asset,
    this.version = '1.0.0',
    this.description = '',
    this.author = 'GhostEcos',
    this.tag,
  });

  final String id;
  final String name;

  /// Путь к встроенному ассету. Пустая строка — только скачиваемое расширение.
  final String asset;
  final String version;
  final String description;
  final String author;

  /// Короткая метка в каталоге: DEFAULT, TEST, BETA и т.п. null — без метки.
  final String? tag;
}

class UiRuntime {
  UiRuntime._();

  static final UiRuntime instance = UiRuntime._();

  static const String prefsKey = 'ui.extension.id';
  static const String defaultId = 'ghost_ui_v2';

  static const String _sourcePrefix = 'ui.extension.source.';
  static const String _metaPrefix = 'ui.extension.meta.';

  /// Встроенные расширения. V2 предустановлен и выбран по умолчанию;
  /// старый дизайн доступен для скачивания из каталога.
  static const List<UiExtensionInfo> extensions = <UiExtensionInfo>[
    UiExtensionInfo(
      id: defaultId,
      name: 'GhostChat V2',
      asset: 'assets/ui/ghost_ui_v2.json',
      version: '1.0.0',
      description:
          'Новый предустановленный дизайн GhostChat: объёмное стекло, мягкие '
          'свечения и обновлённые панели.',
      author: 'GhostEcos',
      tag: 'DEFAULT',
    ),
    UiExtensionInfo(
      id: 'ghost_default',
      name: 'Старый дизайн',
      asset: 'assets/ui/ghost_default.json',
      version: '1.0.0',
      description:
          'Классическое оформление GhostChat: тёмное стекло, привычная сетка '
          'и спокойные акценты.',
      author: 'GhostEcos',
    ),
  ];

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final ValueNotifier<String> currentId = ValueNotifier<String>(defaultId);
  final ValueNotifier<List<String>> lastErrors =
      ValueNotifier<List<String>>(const <String>[]);

  final Map<String, UiExtensionInfo> _downloaded = <String, UiExtensionInfo>{};
  final Set<String> _installed = <String>{defaultId};
  UiConfig _config = UiConfig.bootstrap();
  UiConfig get config => _config;

  UiExtensionInfo get currentExtension => _infoFor(currentId.value);

  bool isInstalled(String id) => _installed.contains(id);

  bool isBuiltIn(String id) => extensions.any((extension) => extension.id == id);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _downloaded.clear();
    _installed
      ..clear()
      ..add(defaultId);

    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_sourcePrefix)) continue;
      final id = key.substring(_sourcePrefix.length);
      if (id.isEmpty) continue;
      _installed.add(id);
      _downloaded[id] = _readMeta(prefs, id);
    }

    final id = prefs.getString(prefsKey) ?? defaultId;
    await _apply(id, prefs: prefs, persist: false);
  }

  Future<void> setExtension(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await _apply(id, prefs: prefs, persist: true);
  }

  /// Ставит скачанный JSON, проверяет его и сразу применяет.
  /// Возвращает false, если конфиг не прошёл валидацию.
  Future<bool> installAndApply(
    String id,
    String source, {
    String? name,
    String? version,
    String? author,
    String? description,
    String? tag,
  }) async {
    final UiConfig parsed;
    try {
      parsed = UiConfig.parse(source);
    } on UiConfigError catch (error) {
      lastErrors.value = error.errors;
      return false;
    } catch (error) {
      lastErrors.value = <String>[error.toString()];
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    final info = UiExtensionInfo(
      id: id,
      name: name?.trim().isNotEmpty == true ? name!.trim() : parsed.name,
      asset: '',
      version: version?.trim().isNotEmpty == true
          ? version!.trim()
          : parsed.version,
      description: description ?? '',
      author: author?.trim().isNotEmpty == true ? author!.trim() : 'GhostEcos',
      tag: tag,
    );

    await prefs.setString(_sourcePrefix + id, source);
    await prefs.setString(
      _metaPrefix + id,
      jsonEncode(<String, String>{
        'name': info.name,
        'version': info.version,
        'description': info.description,
        'author': info.author,
      }),
    );

    _downloaded[id] = info;
    _installed.add(id);
    _config = parsed;
    lastErrors.value = const <String>[];
    currentId.value = id;
    await prefs.setString(prefsKey, id);
    revision.value++;
    return true;
  }

  Future<void> _apply(
    String id, {
    required SharedPreferences prefs,
    required bool persist,
  }) async {
    final info = _infoFor(id);
    var source = prefs.getString(_sourcePrefix + id);

    if (source == null && info.asset.isNotEmpty) {
      try {
        source = await rootBundle.loadString(info.asset);
      } catch (_) {
        source = null;
      }
    }

    if (source == null || source.isEmpty) {
      lastErrors.value = <String>[
        'Расширение «${info.name}» не установлено',
      ];
      await _fallbackToDefault(prefs, persist: persist);
      return;
    }

    try {
      final parsed = UiConfig.parse(source);
      _config = parsed;
      lastErrors.value = const <String>[];
      currentId.value = info.id;
      if (persist) await prefs.setString(prefsKey, info.id);
    } on UiConfigError catch (error) {
      // Битое расширение не роняет приложение: откат на дефолт + диагностика.
      lastErrors.value = error.errors;
      await _fallbackToDefault(prefs, persist: persist);
      return;
    } catch (error) {
      lastErrors.value = <String>[error.toString()];
      await _fallbackToDefault(prefs, persist: persist);
      return;
    }
    revision.value++;
  }

  Future<void> _fallbackToDefault(
    SharedPreferences prefs, {
    required bool persist,
  }) async {
    try {
      final source = await rootBundle.loadString(
        'assets/ui/ghost_ui_v2.json',
      );
      _config = UiConfig.parse(source);
    } catch (_) {
      _config = UiConfig.bootstrap();
    }
    currentId.value = defaultId;
    if (persist) await prefs.remove(prefsKey);
    revision.value++;
  }

  UiExtensionInfo _infoFor(String id) {
    final downloaded = _downloaded[id];
    if (downloaded != null) return downloaded;
    for (final extension in extensions) {
      if (extension.id == id) return extension;
    }
    return UiExtensionInfo(
      id: id,
      name: id,
      asset: '',
      description: 'Расширение не установлено',
    );
  }

  UiExtensionInfo _readMeta(SharedPreferences prefs, String id) {
    final fallback = _infoForBuiltIn(id) ??
        UiExtensionInfo(
          id: id,
          name: id,
          asset: '',
          description: 'Скачанное расширение',
        );
    final raw = prefs.getString(_metaPrefix + id);
    if (raw == null || raw.isEmpty) return fallback;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return fallback;
      final map = Map<String, dynamic>.from(decoded);
      return UiExtensionInfo(
        id: id,
        name: (map['name'] ?? fallback.name).toString(),
        asset: '',
        version: (map['version'] ?? fallback.version).toString(),
        description: (map['description'] ?? fallback.description).toString(),
        author: (map['author'] ?? fallback.author).toString(),
        tag: fallback.tag,
      );
    } catch (_) {
      return fallback;
    }
  }

  static UiExtensionInfo? _infoForBuiltIn(String id) {
    for (final extension in extensions) {
      if (extension.id == id) return extension;
    }
    return null;
  }
}
