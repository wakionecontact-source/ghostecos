/// Доступ виджетов к разрешённому конфигу GhostUI.
library;

import 'package:flutter/material.dart';

import 'ui_config.dart';
import 'ui_runtime.dart';
import 'ui_tokens.dart';

class UiStyle {
  const UiStyle({required this.tokens, required this.values});

  final UiTokens tokens;
  final Map<String, Object> values;

  Color color(String prop, {required Color fallback}) {
    final value = values[prop];
    return value is int ? Color(value) : fallback;
  }

  double number(String prop, {required double fallback}) {
    final value = values[prop];
    return value is num ? value.toDouble() : fallback;
  }

  bool flag(String prop, {required bool fallback}) {
    final value = values[prop];
    return value is bool ? value : fallback;
  }

  String text(String prop, {required String fallback}) {
    final value = values[prop];
    return value is String ? value : fallback;
  }

  /// Радиус ступени. Никогда не берётся из элемента напрямую — только из
  /// глобального мастер-радиуса.
  double radius([String prop = 'radius']) {
    final step = values[prop];
    return tokens.radiusStep(step is String ? step : 'm');
  }

  Color token(String name, {required Color fallback}) =>
      tokens.color(name, fallback: fallback);
}

class UiScope extends InheritedWidget {
  const UiScope({super.key, required this.config, required super.child});

  final UiConfig config;

  static UiConfig configOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<UiScope>();
    return scope?.config ?? UiRuntime.instance.config;
  }

  static UiStyle styleOf(BuildContext context, String element) {
    final config = configOf(context);
    return UiStyle(tokens: config.tokens, values: config.valuesOf(element));
  }

  @override
  bool updateShouldNotify(UiScope oldWidget) => oldWidget.config != config;
}
