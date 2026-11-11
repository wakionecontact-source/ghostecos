/// Рантайм GhostUI: загрузка конфига-расширения, откат на дефолт при ошибке.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import 'ui_config.dart';

class UiExtensionInfo {
  const UiExtensionInfo({
    required this.id,
    required this.name,
    required this.asset,
  });

  final String id;
  final String name;
  final String asset;
}

class UiRuntime {
  UiRuntime._();

  static final UiRuntime instance = UiRuntime._();

  static const String prefsKey = 'ui.extension.id';
  static const String defaultId = 'ghost_default';

  /// MVP-каталог: встроенные конфиги. Позже сюда приедет GhostGallery.
  static const List<UiExtensionInfo> extensions = <UiExtensionInfo>[
    UiExtensionInfo(
      id: defaultId,
      name: 'Ghost Default',
      asset: 'assets/ui/ghost_default.json',
    ),
    UiExtensionInfo(
      id: 'ghost_aurora_test',
      name: 'Aurora (test)',
      asset: 'assets/ui/ghost_aurora_test.json',
    ),
  ];

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final ValueNotifier<String> currentId = ValueNotifier<String>(defaultId);
  final ValueNotifier<List<String>> lastErrors =
      ValueNotifier<List<String>>(const <String>[]);

  UiConfig _config = UiConfig.bootstrap();
  UiConfig get config => _config;

  UiExtensionInfo get currentExtension => _infoFor(currentId.value);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(prefsKey) ?? defaultId;
    await _apply(id, prefs: prefs, persist: false);
  }

  Future<void> setExtension(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await _apply(id, prefs: prefs, persist: true);
  }

  Future<void> _apply(
    String id, {
    required SharedPreferences prefs,
    required bool persist,
  }) async {
    final info = _infoFor(id);
    try {
      final source = await rootBundle.loadString(info.asset);
      final parsed = UiConfig.parse(source);
      _config = parsed;
      lastErrors.value = const <String>[];
      currentId.value = info.id;
      if (persist) await prefs.setString(prefsKey, info.id);
    } on UiConfigError catch (error) {
      // Битое расширение не роняет приложение: откат на дефолт + диагностика.
      lastErrors.value = error.errors;
      _config = UiConfig.bootstrap();
      currentId.value = defaultId;
      if (persist) await prefs.remove(prefsKey);
    } catch (error) {
      lastErrors.value = <String>[error.toString()];
      _config = UiConfig.bootstrap();
      currentId.value = defaultId;
      if (persist) await prefs.remove(prefsKey);
    }
    revision.value++;
  }

  static UiExtensionInfo _infoFor(String id) {
    for (final extension in extensions) {
      if (extension.id == id) return extension;
    }
    return extensions.first;
  }
}
