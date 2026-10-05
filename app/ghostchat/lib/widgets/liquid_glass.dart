/// The native card refraction used by the GhostEcos landing page.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/local/app_logger.dart';

/// Parameters copied from the landing page's `lensMap` pipeline.
///
/// The landing page uses `d = max(8, round(min(w, h) * .1 / 8) * 8)` and a
/// displacement-map scale of 75. The native shader uses the same values and
/// reconstructs the rounded-rectangle map directly at each fragment.
@immutable
class LiquidLensSpec {
  const LiquidLensSpec({
    required this.displacementScale,
    required this.depthFraction,
    required this.minDepthPx,
    required this.geometryBatchPx,
  });

  /// The `feDisplacementMap scale` used by the landing page.
  final double displacementScale;

  /// The `min(w, h) * .1` part of the landing page's `dp` calculation.
  final double depthFraction;

  /// The lower bound used by the landing page for `dp`.
  final double minDepthPx;

  /// Width quantisation used by `batch()` in the landing page.
  final double geometryBatchPx;

  static const native = LiquidLensSpec(
    displacementScale: 75,
    depthFraction: 0.1,
    minDepthPx: 8,
    geometryBatchPx: 8,
  );
}

/// Loads the native lens filter.
class LiquidGlassEngine {
  LiquidGlassEngine._();

  static const LiquidLensSpec lens = LiquidLensSpec.native;
  static const double borderOpacity = 0.13;
  static const double cardShadowOpacity = 0.28;
  static const double cardShadowBlur = 48;
  static const double cardShadowDy = 16;

  static final ValueNotifier<bool> shaderReadyNotifier = ValueNotifier(false);
  static ui.FragmentProgram? _program;
  static Future<void>? _initialization;
  static final Map<int, ui.ImageFilter> _blurCache = <int, ui.ImageFilter>{};

  static Future<void> initialize() {
    return _initialization ??= _loadShader();
  }

  static Future<void> _loadShader() async {
    if (!ui.ImageFilter.isShaderFilterSupported) {
      appLog.warn(
        'ui',
        'Liquid Glass refraction is unavailable: Impeller is off',
      );
      return;
    }
    try {
      _program = await ui.FragmentProgram.fromAsset(
        'shaders/liquid_glass.frag',
      );
      shaderReadyNotifier.value = true;
      appLog.info('ui', 'Liquid Glass refraction shader loaded');
    } catch (_) {
      appLog.warn('ui', 'Liquid Glass refraction shader failed to load');
    }
  }

  static ui.ImageFilter? refractionFilter({
    double radius = 0,
    double devicePixelRatio = 1,
  }) {
    final program = _program;
    if (program == null || !ui.ImageFilter.isShaderFilterSupported) return null;

    final shader = program.fragmentShader();
    // u_size is supplied by ImageFilter.shader. The first user float starts
    // at index 2 because the input sampler does not occupy a float slot.
    final radiusPx = (radius * devicePixelRatio).clamp(0.0, 4096.0).toDouble();
    shader.setFloat(2, radiusPx);
    shader.setFloat(3, lens.displacementScale);
    shader.setFloat(4, lens.depthFraction);
    shader.setFloat(5, lens.minDepthPx);
    shader.setFloat(6, lens.geometryBatchPx);
    return ui.ImageFilter.shader(shader);
  }

  /// Keeps the theme's border tint while matching the landing page's thin
  /// highlight edge.
  static int borderColorValue(int argb) {
    final rgb = argb & 0x00ffffff;
    final alpha = (borderOpacity * 255).round();
    return (alpha << 24) | rgb;
  }

  /// Legacy blur helper retained for buttons, inputs and bars. GlassCard uses
  /// only [refractionFilter] when the liquid-glass switch is enabled.
  static ui.ImageFilter blurFilter(double sigma) {
    final safeSigma = sigma.clamp(0.5, 24.0).toDouble();
    final key = (safeSigma * 2).round();
    return _blurCache.putIfAbsent(
      key,
      () => ui.ImageFilter.blur(
        sigmaX: key / 2,
        sigmaY: key / 2,
        tileMode: ui.TileMode.clamp,
      ),
    );
  }
}
