/// Разбор и строгая валидация конфига GhostUI.
///
/// Правила:
///  • каждый элемент из реестра обязан иметь конфиг;
///  • неизвестный элемент/свойство — ошибка;
///  • обязательное свойство отсутствует — ошибка;
///  • радиус у элемента запрещён: он задаётся только глобально;
///  • заблокированные элементы оформлять нельзя.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import 'ui_registry.dart';
import 'ui_tokens.dart';

class UiConfigError implements Exception {
  UiConfigError(this.errors);

  final List<String> errors;

  @override
  String toString() => 'UiConfigError:\n${errors.join('\n')}';
}

class UiConfig {
  UiConfig({
    required this.id,
    required this.name,
    required this.version,
    required this.apiVersion,
    required this.tokens,
    required Map<String, Map<String, Object>> elements,
  }) : _elements = Map<String, Map<String, Object>>.unmodifiable(
         elements.map(
           (k, v) => MapEntry(k, Map<String, Object>.unmodifiable(v)),
         ),
       );

  final String id;
  final String name;
  final String version;
  final int apiVersion;
  final UiTokens tokens;
  final Map<String, Map<String, Object>> _elements;

  static const int supportedApiVersion = 1;

  Map<String, Object> valuesOf(String element) =>
      _elements[element] ?? const <String, Object>{};

  Iterable<String> get elementIds => _elements.keys;

  /// Конфиг-заглушка на случай, если ассет не загрузился. Приложение обязано
  /// запуститься даже с битым конфигом.
  static UiConfig bootstrap() => UiConfig(
    id: 'bootstrap',
    name: 'Bootstrap',
    version: '0',
    apiVersion: supportedApiVersion,
    tokens: UiTokens.bootstrap(),
    elements: const <String, Map<String, Object>>{},
  );

  /// Разбирает JSON-строку. Бросает [UiConfigError] со списком всех проблем,
  /// а не падает на первой — так удобнее править конфиг.
  static UiConfig parse(String source, {UiRegistry? registry}) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(source);
    } catch (e) {
      throw UiConfigError(<String>['JSON: $e']);
    }
    if (decoded is! Map<String, dynamic>) {
      throw UiConfigError(<String>['Корень конфига должен быть JSON-объектом']);
    }
    return fromMap(decoded, registry: registry ?? UiRegistry.instance);
  }

  static UiConfig fromMap(
    Map<String, dynamic> map, {
    UiRegistry? registry,
  }) {
    final reg = registry ?? UiRegistry.instance;
    final errors = <String>[];

    String readString(String key) {
      final v = map[key];
      if (v is String && v.trim().isNotEmpty) return v;
      errors.add('$key: обязательная непустая строка');
      return '';
    }

    final id = readString('id');
    final name = readString('name');
    final version = readString('version');

    final apiVersionRaw = map['apiVersion'];
    var apiVersion = 0;
    if (apiVersionRaw is int) {
      apiVersion = apiVersionRaw;
    } else {
      errors.add('apiVersion: обязательное целое число');
    }
    if (apiVersion != supportedApiVersion && apiVersion != 0) {
      errors.add(
        'apiVersion: поддерживается только $supportedApiVersion, получено $apiVersion',
      );
    }

    // ── Токены ────────────────────────────────────────────────────────────
    final bootstrap = UiTokens.bootstrap();
    final colors = Map<String, Color>.from(bootstrap.colors);
    var radius = bootstrap.radius;
    final spacing = Map<String, double>.from(bootstrap.spacing);

    final tokensRaw = map['tokens'];
    if (tokensRaw is! Map) {
      errors.add('tokens: обязательный объект');
    } else {
      final rawColors = tokensRaw['colors'];
      if (rawColors is Map) {
        for (final entry in rawColors.entries) {
          final key = entry.key.toString();
          final value = entry.value;
          if (value is! String) {
            errors.add('tokens.colors.$key: ожидается строка с цветом');
            continue;
          }
          final parsed = _parseColor(
            value,
            const <String, Color>{},
            errors,
            'tokens.colors.$key',
            allowTokens: false,
          );
          if (parsed != null) colors[key] = parsed;
        }
      }

      final rawRadius = tokensRaw['radius'];
      if (rawRadius != null) {
        if (rawRadius is num && rawRadius >= 0 && rawRadius <= 48) {
          radius = rawRadius.toDouble();
        } else {
          errors.add('tokens.radius: число 0..48');
        }
      }

      final rawSpacing = tokensRaw['spacing'];
      if (rawSpacing is Map) {
        for (final entry in rawSpacing.entries) {
          final value = entry.value;
          if (value is num) {
            spacing[entry.key.toString()] = value.toDouble();
          } else {
            errors.add('tokens.spacing.${entry.key}: ожидается число');
          }
        }
      }
    }

    final tokens = UiTokens(colors: colors, radius: radius, spacing: spacing);

    // ── Элементы ──────────────────────────────────────────────────────────
    final elements = <String, Map<String, Object>>{};
    final elementsRaw = map['elements'];

    if (elementsRaw is! Map) {
      errors.add('elements: обязательный объект');
    } else {
      for (final spec in reg.styleable) {
        if (!elementsRaw.containsKey(spec.id)) {
          errors.add(
            'Нет конфига для элемента "${spec.id}" — каждый элемент реестра обязан быть описан',
          );
        }
      }

      for (final entry in elementsRaw.entries) {
        final elementId = entry.key.toString();
        final spec = reg.byId(elementId);
        if (spec == null) {
          errors.add('Неизвестный элемент "$elementId"');
          continue;
        }
        if (spec.isLocked) {
          errors.add(
            'Элемент "$elementId" заблокирован и не может быть оформлен расширением',
          );
          continue;
        }
        final rawProps = entry.value;
        if (rawProps is! Map) {
          errors.add('$elementId: ожидается объект свойств');
          continue;
        }

        final resolved = <String, Object>{};
        for (final propEntry in spec.props.entries) {
          final prop = propEntry.value;
          final hasValue = rawProps.containsKey(propEntry.key);
          final raw = hasValue ? rawProps[propEntry.key] : prop.defaultValue;
          if (raw == null) {
            if (prop.required) {
              errors.add(
                '$elementId.${propEntry.key}: обязательное свойство отсутствует',
              );
            }
            continue;
          }
          final value = _resolveProp(
            elementId: elementId,
            propName: propEntry.key,
            spec: prop,
            raw: raw,
            tokens: tokens,
            errors: errors,
          );
          if (value != null) resolved[propEntry.key] = value;
        }

        for (final key in rawProps.keys) {
          final name = key.toString();
          if (spec.props.containsKey(name)) continue;
          if (name == 'radius') {
            errors.add(
              '$elementId.radius: радиус задаётся только глобально (tokens.radius)',
            );
          } else {
            errors.add('$elementId.$name: неизвестное свойство');
          }
        }

        elements[elementId] = resolved;
      }
    }

    if (errors.isNotEmpty) throw UiConfigError(errors);

    return UiConfig(
      id: id,
      name: name,
      version: version,
      apiVersion: apiVersion,
      tokens: tokens,
      elements: elements,
    );
  }

  static Object? _resolveProp({
    required String elementId,
    required String propName,
    required UiPropSpec spec,
    required Object raw,
    required UiTokens tokens,
    required List<String> errors,
  }) {
    final where = '$elementId.$propName';
    switch (spec.type) {
      case UiPropType.color:
        if (raw is! String) {
          errors.add('$where: ожидается строка с цветом');
          return null;
        }
        return _parseColor(raw, tokens.colors, errors, where);
      case UiPropType.number:
        if (raw is! num) {
          errors.add('$where: ожидается число');
          return null;
        }
        final value = raw.toDouble();
        if (spec.min != null && value < spec.min!) {
          errors.add('$where: минимум ${spec.min}');
          return null;
        }
        if (spec.max != null && value > spec.max!) {
          errors.add('$where: максимум ${spec.max}');
          return null;
        }
        return value;
      case UiPropType.boolean:
        if (raw is! bool) {
          errors.add('$where: ожидается true/false');
          return null;
        }
        return raw;
      case UiPropType.choice:
        if (raw is! String || !(spec.choices ?? const []).contains(raw)) {
          errors.add('$where: допустимо ${spec.choices?.join(' | ')}');
          return null;
        }
        return raw;
      case UiPropType.radiusStep:
        if (raw is num) {
          errors.add('$where: радиус задаётся только глобально (tokens.radius)');
          return null;
        }
        if (raw is! String ||
            (raw != 'pill' && !uiRadiusSteps.containsKey(raw))) {
          errors.add(
            '$where: допустимо ${uiRadiusSteps.keys.join(' | ')} | pill',
          );
          return null;
        }
        return raw;
      case UiPropType.text:
        if (raw is! String) {
          errors.add('$where: ожидается строка');
          return null;
        }
        return raw;
    }
  }

  static Color? _parseColor(
    String raw,
    Map<String, Color> tokens,
    List<String> errors,
    String where, {
    bool allowTokens = true,
  }) {
    if (raw == 'transparent') return const Color(0x00000000);
    if (raw.startsWith('token:')) {
      if (!allowTokens) {
        errors.add('$where: токены не могут ссылаться на другие токены');
        return null;
      }
      final name = raw.substring('token:'.length);
      final color = tokens[name];
      if (color == null) {
        errors.add('$where: неизвестный токен "$name"');
      }
      return color;
    }
    if (raw.startsWith('#')) {
      var hex = raw.substring(1);
      if (hex.length == 6) hex = 'FF$hex';
      if (hex.length != 8) {
        errors.add('$where: ожидается #RRGGBB или #AARRGGBB');
        return null;
      }
      final value = int.tryParse(hex, radix: 16);
      if (value == null) {
        errors.add('$where: некорректный цвет "$raw"');
        return null;
      }
      return Color(value);
    }
    errors.add('$where: ожидается token:name, #RRGGBB или transparent');
    return null;
  }
}
