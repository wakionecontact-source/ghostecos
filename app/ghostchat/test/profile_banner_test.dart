import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ghost/theme.dart';
import 'package:ghost/widgets/avatar.dart';
import 'package:ghost/widgets/profile_banner.dart';

void main() {
  test('missing banner stays empty for channels and groups', () {
    final banner = ProfileBannerConfig.fromDynamic(null);

    expect(banner, isNull);
    final defaults = ProfileBannerConfig.defaultGradient().toJson();
    expect(defaults['type'], 'lights');
    expect(defaults['colors'], ['#7C3AED', '#A855F7']);
    expect(defaults['background_color'], '#020617');
    expect(defaults['lights'], hasLength(2));
    expect(defaults['lights'][0]['color_index'], 0);
    expect(defaults['lights'][1]['color_index'], 1);
  });

  test('lights keep one draggable source and strength per color', () {
    final light = ProfileBannerLight(
      colorIndex: 0,
      position: const Offset(0.2, 0.3),
      strength: 0.8,
    );
    expect(light.toJson(), {
      'color_index': 0,
      'position': [0.0, 0.3],
      'strength': 0.8,
    });

    final config = ProfileBannerConfig.fromDynamic({
      'type': 'lights',
      'colors': ['#112233', '#AABBCC'],
      'lights': [
        light.toJson(),
        {
          'color_index': 1,
          'position': [1.0, 0.7],
          'strength': 0.4,
          // Old saved configs may still contain this field; it is ignored.
          'direction': 135,
        },
      ],
    });

    expect(config, isNotNull);
    expect(config!.lights, hasLength(2));
    expect(config.lights[1].position, const Offset(1.0, 0.7));
    expect(config.lights[1].strength, 0.4);
    expect(config.backgroundColor, const Color(0xFF020617));
    expect(config.toJson()['lights'], [
      light.toJson(),
      {
        'color_index': 1,
        'position': [1.0, 0.7],
        'strength': 0.4,
      },
    ]);
    expect(config.toJson()['background_color'], '#020617');
  });

  test('banner config round-trips solid and linear values', () {
    final linear = ProfileBannerConfig.fromDynamic({
      'type': 'linear',
      'colors': ['#112233', '#AABBCC'],
      'stops': [0, 0.75],
      'angle': 225,
      'lights': [
        {
          'color_index': 1,
          'position': [0.0, 0.3],
          'strength': 0.8,
        },
      ],
    });

    expect(linear, isNotNull);
    expect(linear!.isGradient, isTrue);
    expect(linear.colors, [const Color(0xFF112233), const Color(0xFFAABBCC)]);
    expect(linear.stops, [0.0, 0.75]);
    expect(linear.angle, 225.0);
    expect(linear.lights, hasLength(1));
    expect(linear.lights.single.colorIndex, 1);
    expect(linear.lights.single.position, const Offset(0.0, 0.3));
    expect(linear.lights.single.strength, 0.8);

    final solid = ProfileBannerConfig.fromDynamic(
      linear
          .copyWith(type: 'solid', colors: [const Color(0xFFABCDEF)])
          .toJson(),
    );
    expect(solid!.isGradient, isFalse);
    expect(solid.colors, [const Color(0xFFABCDEF)]);
  });

  test('avatar corner follows the global corner setting', () {
    final previous = GE.cornerFactor;
    try {
      GE.cornerFactor = 0.0;
      expect(ghostAvatarCornerRadius(48), 0.0);
      GE.cornerFactor = 0.5;
      expect(ghostAvatarCornerRadius(48), 12.0);
      GE.cornerFactor = 1.0;
      expect(ghostAvatarCornerRadius(48), 24.0);
    } finally {
      GE.cornerFactor = previous;
    }
  });
}
