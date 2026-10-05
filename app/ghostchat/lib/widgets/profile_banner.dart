import 'dart:math' as math;
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import '../services/theme_service.dart';
import 'color_picker_panel.dart';

const _defaultBannerBackground = Color(0xFF020617);

/// A small, server-safe description of a profile/channel/group banner.
///
/// The actual profile layout deliberately stays outside this model: the
/// banner is only a clipped visual layer and never changes the profile data.
class ProfileBannerLight {
  final int colorIndex;
  final Offset position;
  final double strength;

  const ProfileBannerLight({
    required this.colorIndex,
    required this.position,
    required this.strength,
  });

  /// Keeps a normalized point on the closest side of the banner perimeter.
  /// This also migrates older saved lights that used an interior point.
  static Offset clampToEdge(Offset point) {
    final clamped = Offset(
      point.dx.clamp(0.0, 1.0).toDouble(),
      point.dy.clamp(0.0, 1.0).toDouble(),
    );
    final distances = <double>[
      clamped.dy,
      1.0 - clamped.dx,
      1.0 - clamped.dy,
      clamped.dx,
    ];
    var nearest = 0;
    for (var index = 1; index < distances.length; index++) {
      if (distances[index] < distances[nearest]) nearest = index;
    }
    switch (nearest) {
      case 0:
        return Offset(clamped.dx, 0.0);
      case 1:
        return Offset(1.0, clamped.dy);
      case 2:
        return Offset(clamped.dx, 1.0);
      default:
        return Offset(0.0, clamped.dy);
    }
  }

  ProfileBannerLight copyWith({
    int? colorIndex,
    Offset? position,
    double? strength,
  }) => ProfileBannerLight(
    colorIndex: colorIndex ?? this.colorIndex,
    position: position ?? this.position,
    strength: strength ?? this.strength,
  );

  Map<String, dynamic> toJson() {
    final edge = clampToEdge(position);
    return {
      'color_index': colorIndex,
      'position': [edge.dx, edge.dy],
      'strength': strength,
    };
  }

  static ProfileBannerLight? fromDynamic(
    Object? raw, {
    required int colorCount,
  }) {
    if (raw is! Map || colorCount <= 0) return null;
    final map = Map<String, dynamic>.from(raw);
    final rawPosition = _parsePoint(map['position']);
    final position = rawPosition == null
        ? null
        : ProfileBannerLight.clampToEdge(rawPosition);
    if (position == null) return null;
    final rawColorIndex = map['color_index'];
    final colorIndex = rawColorIndex is num
        ? rawColorIndex.toInt().clamp(0, colorCount - 1).toInt()
        : 0;
    final rawStrength = map['strength'];
    final strength = rawStrength is num && rawStrength.toDouble().isFinite
        ? rawStrength.toDouble().clamp(0.0, 1.0).toDouble()
        : 0.65;
    return ProfileBannerLight(
      colorIndex: colorIndex,
      position: position,
      strength: strength,
    );
  }

  static Offset? _parsePoint(Object? raw) {
    if (raw is! List || raw.length != 2) return null;
    final x = raw[0];
    final y = raw[1];
    if (x is! num || y is! num) return null;
    final point = Offset(x.toDouble(), y.toDouble());
    if (!point.dx.isFinite ||
        !point.dy.isFinite ||
        point.dx < 0 ||
        point.dx > 1 ||
        point.dy < 0 ||
        point.dy > 1) {
      return null;
    }
    return point;
  }
}

class ProfileBannerConfig {
  final String type;
  final List<Color> colors;
  final Color backgroundColor;
  final List<double> stops;
  final double angle;
  final List<ProfileBannerLight> lights;

  const ProfileBannerConfig({
    required this.type,
    required this.colors,
    this.backgroundColor = _defaultBannerBackground,
    required this.stops,
    required this.angle,
    this.lights = const [],
  });

  bool get isGradient => type != 'solid' && colors.length > 1;
  bool get hasLight => lights.isNotEmpty;

  static ProfileBannerConfig? fromDynamic(Object? raw) {
    if (raw == null) return null;
    Object? value = raw;
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        value = jsonDecode(raw);
      } catch (_) {
        return null;
      }
    }
    if (value is! Map) return null;
    final map = Map<String, dynamic>.from(value);
    final rawColors = map['colors'];
    if (rawColors is! List) return null;
    final colors = rawColors
        .map(_parseColor)
        .whereType<Color>()
        .take(10)
        .toList(growable: false);
    if (colors.isEmpty) return null;
    final backgroundColor =
        _parseColor(map['background_color'] ?? map['background']) ??
        _defaultBannerBackground;

    final rawStops = map['stops'];
    final stops = rawStops is List
        ? rawStops
              .map((value) => value is num ? value.toDouble() : double.nan)
              .toList(growable: false)
        : const <double>[];
    final safeStops = stops.length == colors.length
        ? stops
              .map(
                (value) =>
                    value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0.0,
              )
              .toList(growable: false)
        : List<double>.generate(
            colors.length,
            (index) => colors.length == 1 ? 0.0 : index / (colors.length - 1),
          );
    final sortedStops = List<double>.from(safeStops);
    for (var i = 1; i < sortedStops.length; i++) {
      if (sortedStops[i] < sortedStops[i - 1]) {
        sortedStops[i] = sortedStops[i - 1];
      }
    }
    final rawAngle = map['angle'];
    final angle = rawAngle is num && rawAngle.toDouble().isFinite
        ? rawAngle.toDouble().clamp(-360.0, 360.0).toDouble()
        : 135.0;
    final type = map['type'] == 'lights'
        ? 'lights'
        : map['type'] == 'linear' && colors.length > 1
        ? 'linear'
        : 'solid';
    final rawLights = map['lights'];
    final lights = rawLights is List
        ? rawLights
              .map(
                (raw) => ProfileBannerLight.fromDynamic(
                  raw,
                  colorCount: colors.length,
                ),
              )
              .whereType<ProfileBannerLight>()
              .take(10)
              .toList(growable: false)
        : _migrateLegacyLight(map, colors.length);
    return ProfileBannerConfig(
      type: type,
      colors: type == 'solid' ? [colors.first] : colors,
      backgroundColor: backgroundColor,
      stops: type == 'solid' ? const [0.0] : sortedStops,
      angle: angle,
      lights: lights,
    );
  }

  static List<ProfileBannerLight> _migrateLegacyLight(
    Map<String, dynamic> map,
    int colorCount,
  ) {
    final source = ProfileBannerLight._parsePoint(map['light']);
    final target = ProfileBannerLight._parsePoint(map['light_target']);
    if (source == null || target == null || colorCount == 0) {
      return const [];
    }
    final vector = target - source;
    final distance = vector.distance;
    return [
      ProfileBannerLight(
        colorIndex: 0,
        position: source,
        strength: (distance / math.sqrt(2)).clamp(0.0, 1.0).toDouble(),
      ),
    ];
  }

  static Color? _parseColor(Object? raw) {
    if (raw is! String) return null;
    var value = raw.trim().replaceFirst('#', '');
    if (value.length == 6) value = 'FF$value';
    if (value.length != 8) return null;
    final parsed = int.tryParse(value, radix: 16);
    return parsed == null ? null : Color(parsed);
  }

  static ProfileBannerConfig defaultGradient() => ProfileBannerConfig(
    type: 'lights',
    colors: [GE.primary2, GE.primary],
    backgroundColor: _defaultBannerBackground,
    stops: const [],
    angle: 0,
    lights: const [
      ProfileBannerLight(
        colorIndex: 0,
        position: Offset(0.24, 0.0),
        strength: 0.7,
      ),
      ProfileBannerLight(
        colorIndex: 1,
        position: Offset(1.0, 0.68),
        strength: 0.7,
      ),
    ],
  );

  Map<String, dynamic> toJson() => {
    'type': type,
    'colors': colors.map(_colorToHex).toList(growable: false),
    'background_color': _colorToHex(backgroundColor),
    if (type != 'lights') 'stops': stops.toList(growable: false),
    if (type != 'lights') 'angle': angle,
    if (lights.isNotEmpty)
      'lights': lights.map((light) => light.toJson()).toList(growable: false),
  };

  ProfileBannerConfig copyWith({
    String? type,
    List<Color>? colors,
    Color? backgroundColor,
    List<double>? stops,
    double? angle,
    List<ProfileBannerLight>? lights,
  }) => ProfileBannerConfig(
    type: type ?? this.type,
    colors: colors ?? this.colors,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    stops: stops ?? this.stops,
    angle: angle ?? this.angle,
    lights: lights ?? this.lights,
  );

  static String _colorToHex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
}

class ProfileBanner extends StatelessWidget {
  final ProfileBannerConfig? config;
  final double height;
  final Widget? child;

  const ProfileBanner({
    super.key,
    required this.config,
    this.height = 112,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final banner = config;
    if (banner == null) return const SizedBox.shrink();
    return ValueListenableBuilder<double>(
      valueListenable: ThemeService.instance.cornerNotifier,
      builder: (context, _, _) => ClipRRect(
        borderRadius: BorderRadius.circular(GE.radiusLg),
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: banner.type == 'lights' ? banner.backgroundColor : null,
            gradient: banner.type == 'lights' ? null : _gradientFor(banner),
          ),
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              if (banner.type == 'lights' || banner.hasLight)
                CustomPaint(painter: _BannerLightPainter(config: banner)),
              ?child,
            ],
          ),
        ),
      ),
    );
  }

  static Gradient _gradientFor(ProfileBannerConfig config) {
    if (config.type == 'lights') {
      return const LinearGradient(
        colors: [Color(0xFF020617), Color(0xFF020617)],
      );
    }
    if (!config.isGradient) {
      return LinearGradient(colors: [config.colors.first]);
    }
    return LinearGradient(
      colors: config.colors,
      stops: config.stops,
      transform: GradientRotation(config.angle * math.pi / 180),
    );
  }
}

class _BannerLightPainter extends CustomPainter {
  final ProfileBannerConfig config;

  const _BannerLightPainter({required this.config});

  @override
  void paint(Canvas canvas, Size size) {
    if (config.type == 'lights') {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = config.backgroundColor,
      );
    }

    var maxStrength = 0.0;
    for (final light in config.lights) {
      final strength = light.strength.clamp(0.0, 1.0).toDouble();
      if (strength <= 0) continue;
      maxStrength = math.max(maxStrength, strength);
      final color = config
          .colors[light.colorIndex.clamp(0, config.colors.length - 1).toInt()];
      final source = Offset(
        light.position.dx * size.width,
        light.position.dy * size.height,
      );
      final maxRadius =
          math.sqrt(size.width * size.width + size.height * size.height) *
          (0.18 + 0.95 * strength);

      // A source only paints its soft radial field. There are no rays,
      // targets, centre vectors, or other directional geometry.
      final shader = RadialGradient(
        colors: [
          color.withValues(alpha: 0.86 * strength),
          color.withValues(alpha: 0.38 * strength),
          color.withValues(alpha: 0.09 * strength),
          Colors.transparent,
        ],
        stops: const [0.0, 0.25, 0.62, 1.0],
      ).createShader(Rect.fromCircle(center: source, radius: maxRadius));
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = shader
          ..blendMode = BlendMode.srcOver,
      );
    }

    // Gradually blend the strongest source(s) over the whole banner as their
    // strength approaches 100%. This keeps the transition continuous instead
    // of jumping on the last slider step. At 100%, equal maximum sources are
    // averaged first, so their result is independent of list order.
    final solidMix = _smoothStep(0.8, 1.0, maxStrength);
    if (solidMix > 0) {
      final weightedColors = <Color, double>{};
      for (final light in config.lights) {
        final strength = light.strength.clamp(0.0, 1.0).toDouble();
        if (strength <= 0) continue;
        final isMaximum = (strength - maxStrength).abs() < 0.0001;
        final weight = isMaximum ? strength : strength * (1.0 - maxStrength);
        if (weight <= 0) continue;
        final color =
            config.colors[light.colorIndex
                .clamp(0, config.colors.length - 1)
                .toInt()];
        weightedColors[color] = (weightedColors[color] ?? 0) + weight;
      }
      if (weightedColors.isNotEmpty) {
        canvas.drawRect(
          Offset.zero & size,
          Paint()
            ..color = _weightedAverageColors(
              weightedColors,
            ).withValues(alpha: solidMix),
        );
      }
    }
  }

  double _smoothStep(double edge0, double edge1, double value) {
    final t = ((value - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }

  Color _weightedAverageColors(Map<Color, double> weightedColors) {
    var red = 0.0;
    var green = 0.0;
    var blue = 0.0;
    var totalWeight = 0.0;
    for (final entry in weightedColors.entries) {
      red += entry.key.r * 255.0 * entry.value;
      green += entry.key.g * 255.0 * entry.value;
      blue += entry.key.b * 255.0 * entry.value;
      totalWeight += entry.value;
    }
    if (totalWeight <= 0) return Colors.transparent;
    return Color.fromARGB(
      255,
      ((red / totalWeight).round()).clamp(0, 255),
      ((green / totalWeight).round()).clamp(0, 255),
      ((blue / totalWeight).round()).clamp(0, 255),
    );
  }

  @override
  bool shouldRepaint(covariant _BannerLightPainter oldDelegate) => true;
}

/// Transparent layout halo between the avatar and the profile background/banner.
/// The surrounding banner is cut out separately, so the profile background is
/// visible through this configured buffer around the avatar.
class ProfileAvatarBuffer extends StatelessWidget {
  final double avatarSize;
  final double buffer;
  final Widget child;

  const ProfileAvatarBuffer({
    super.key,
    required this.avatarSize,
    required this.buffer,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final outerSize = avatarSize + buffer * 2;
    return SizedBox(
      width: outerSize,
      height: outerSize,
      child: Center(
        child: SizedBox(width: avatarSize, height: avatarSize, child: child),
      ),
    );
  }
}

class _ProfileBannerHoleClipper extends CustomClipper<Path> {
  final double bannerHeight;
  final double avatarOuterSize;
  final bool alignAvatarLeft;
  final double cornerFactor;

  const _ProfileBannerHoleClipper({
    required this.bannerHeight,
    required this.avatarOuterSize,
    required this.alignAvatarLeft,
    required this.cornerFactor,
  });

  @override
  Path getClip(Size size) {
    final centerX = alignAvatarLeft ? avatarOuterSize / 2 : size.width / 2;
    final holeRect = Rect.fromCenter(
      center: Offset(centerX, bannerHeight),
      width: avatarOuterSize,
      height: avatarOuterSize,
    );
    final holeRadius = (avatarOuterSize * 0.5 * cornerFactor).clamp(
      0.0,
      avatarOuterSize * 0.5,
    );
    final hole = RRect.fromRectAndRadius(holeRect, Radius.circular(holeRadius));
    final path = Path()..fillType = PathFillType.evenOdd;

    // The banner ends at the avatar centre line. The oval is a transparent
    // hole for the avatar buffer; there is deliberately no convex lip/skirt.
    path
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, bannerHeight)
      ..lineTo(0, bannerHeight);
    path
      ..close()
      ..addRRect(hole);
    return path;
  }

  @override
  bool shouldReclip(covariant _ProfileBannerHoleClipper oldClipper) =>
      oldClipper.bannerHeight != bannerHeight ||
      oldClipper.avatarOuterSize != avatarOuterSize ||
      oldClipper.alignAvatarLeft != alignAvatarLeft ||
      oldClipper.cornerFactor != cornerFactor;
}

/// Banner and avatar stage shared by the full profile and the settings
/// preview. The banner ends at the avatar centre line; the avatar's opaque
/// buffer continues below that line by the configured amount.
class ProfileBannerAvatarStage extends StatelessWidget {
  final ProfileBannerConfig? banner;
  final Widget avatar;
  final double avatarSize;
  final double bannerHeight;
  final bool alignAvatarLeft;

  const ProfileBannerAvatarStage({
    super.key,
    required this.banner,
    required this.avatar,
    this.avatarSize = 96,
    this.bannerHeight = 96,
    this.alignAvatarLeft = false,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: ThemeService.instance.avatarBannerBufferNotifier,
      builder: (context, buffer, _) {
        return ValueListenableBuilder<double>(
          valueListenable: ThemeService.instance.cornerNotifier,
          builder: (context, cornerFactor, _) {
            if (banner == null) {
              return SizedBox(
                width: double.infinity,
                height: avatarSize + 12,
                child: alignAvatarLeft
                    ? Align(alignment: Alignment.centerLeft, child: avatar)
                    : Center(child: avatar),
              );
            }
            // The configured buffer is reduced as the avatar becomes rounder.
            // A square avatar keeps the full gap; a circular avatar uses a
            // tighter cutout so the banner does not leave a visible skirt.
            final effectiveBuffer = buffer * (1.0 - 0.5 * cornerFactor);
            final avatarOuterSize = avatarSize + effectiveBuffer * 2;
            final avatarTop = bannerHeight - avatarOuterSize / 2;
            final avatarWidget = ProfileAvatarBuffer(
              avatarSize: avatarSize,
              buffer: effectiveBuffer,
              child: avatar,
            );
            return SizedBox(
              width: double.infinity,
              height: bannerHeight + avatarOuterSize / 2 + 12,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: bannerHeight,
                    child: ClipPath(
                      clipper: _ProfileBannerHoleClipper(
                        bannerHeight: bannerHeight,
                        avatarOuterSize: avatarOuterSize,
                        alignAvatarLeft: alignAvatarLeft,
                        cornerFactor: cornerFactor,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: ProfileBanner(
                        config: banner,
                        height: bannerHeight,
                      ),
                    ),
                  ),
                  if (alignAvatarLeft)
                    Positioned(left: 0, top: avatarTop, child: avatarWidget)
                  else
                    Positioned(
                      top: avatarTop,
                      left: 0,
                      right: 0,
                      child: Center(child: avatarWidget),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// Shared profile composition. The banner bottom is exactly at the avatar's
/// centre line; the content below it starts after a deliberate buffer.
class ProfileBannerHeader extends StatelessWidget {
  final ProfileBannerConfig? banner;
  final Widget avatar;
  final Widget identity;
  final double avatarSize;
  final double bannerHeight;

  const ProfileBannerHeader({
    super.key,
    required this.banner,
    required this.avatar,
    required this.identity,
    this.avatarSize = 96,
    this.bannerHeight = 96,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ProfileBannerAvatarStage(
          banner: banner,
          avatar: avatar,
          avatarSize: avatarSize,
          bannerHeight: bannerHeight,
        ),
        identity,
      ],
    );
  }
}

class ProfileBannerEditResult {
  final ProfileBannerConfig? config;
  final bool clear;

  const ProfileBannerEditResult._({this.config, this.clear = false});

  const ProfileBannerEditResult.save(ProfileBannerConfig config)
    : this._(config: config);

  const ProfileBannerEditResult.clear() : this._(clear: true);
}

Future<ProfileBannerEditResult?> showProfileBannerEditor(
  BuildContext context, {
  ProfileBannerConfig? initial,
}) {
  return showModalBottomSheet<ProfileBannerEditResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ProfileBannerEditorSheet(initial: initial),
  );
}

class _ProfileBannerEditorSheet extends StatefulWidget {
  final ProfileBannerConfig? initial;

  const _ProfileBannerEditorSheet({this.initial});

  @override
  State<_ProfileBannerEditorSheet> createState() =>
      _ProfileBannerEditorSheetState();
}

class _ProfileBannerEditorSheetState extends State<_ProfileBannerEditorSheet> {
  late List<Color> _colors;
  late List<ProfileBannerLight> _lights;
  late Color _backgroundColor;
  int _selectedColorIndex = 0;
  int? _draggingLightIndex;

  static const _previewHeight = 188.0;

  @override
  void initState() {
    super.initState();
    final value = widget.initial ?? ProfileBannerConfig.defaultGradient();
    _colors = List<Color>.from(value.colors);
    _lights = _syncLightsToColors(value.lights, _colors.length);
    _backgroundColor = value.backgroundColor;
  }

  ProfileBannerConfig get _draft => ProfileBannerConfig(
    type: 'lights',
    colors: _colors,
    backgroundColor: _backgroundColor,
    stops: const [],
    angle: 0,
    lights: _lights,
  );

  List<ProfileBannerLight> _syncLightsToColors(
    List<ProfileBannerLight> lights,
    int colorCount,
  ) {
    if (colorCount <= 0) return const [];
    final byColor = <int, ProfileBannerLight>{};
    for (final light in lights) {
      if (light.colorIndex >= 0 &&
          light.colorIndex < colorCount &&
          !byColor.containsKey(light.colorIndex)) {
        byColor[light.colorIndex] = light;
      }
    }
    return List<ProfileBannerLight>.generate(colorCount, (index) {
      final light = byColor[index] ?? _newLight(index, index);
      return light.copyWith(
        colorIndex: index,
        position: ProfileBannerLight.clampToEdge(light.position),
      );
    });
  }

  List<ProfileBannerLight> _reindexLights(
    List<ProfileBannerLight> lights,
    int colorCount,
  ) => List<ProfileBannerLight>.generate(colorCount, (index) {
    final light = index < lights.length
        ? lights[index]
        : _newLight(index, index);
    return light.copyWith(
      colorIndex: index,
      position: ProfileBannerLight.clampToEdge(light.position),
    );
  });

  Offset _clampPoint(Offset point) => ProfileBannerLight.clampToEdge(point);

  Offset _toNormalized(Offset local, Size size) => _clampPoint(
    Offset(
      size.width == 0 ? 0.5 : local.dx / size.width,
      size.height == 0 ? 0.5 : local.dy / size.height,
    ),
  );

  void _beginHandleDrag(Offset local, Size size) {
    // Each color has exactly one draggable source point. The light is
    // nondirectional, so there is deliberately no target/angle handle.
    const hitRadius = 52.0;
    int? sourceIndex;
    var closestSourceDistance = double.infinity;
    for (var index = 0; index < _lights.length; index++) {
      final light = _lights[index];
      final source = Offset(
        light.position.dx * size.width,
        light.position.dy * size.height,
      );
      final sourceDistance = (local - source).distance;
      if (sourceDistance < closestSourceDistance) {
        closestSourceDistance = sourceDistance;
        sourceIndex = index;
      }
    }
    if (sourceIndex == null || closestSourceDistance > hitRadius) return;
    setState(() {
      _selectedColorIndex = sourceIndex!;
      _draggingLightIndex = sourceIndex;
    });
  }

  void _dragHandle(Offset local, Size size) {
    if (_draggingLightIndex == null) return;
    final index = _draggingLightIndex!;
    final light = _lights[index];
    final next = light.copyWith(position: _toNormalized(local, size));
    final lights = List<ProfileBannerLight>.from(_lights);
    lights[index] = next;
    setState(() => _lights = lights);
  }

  void _endHandleDrag() {
    if (_draggingLightIndex == null) return;
    setState(() => _draggingLightIndex = null);
  }

  Widget _buildInteractivePreview() => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, _previewHeight);
      return SizedBox(
        height: _previewHeight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) =>
              _beginHandleDrag(details.localPosition, size),
          onPanUpdate: (details) => _dragHandle(details.localPosition, size),
          onPanEnd: (_) => _endHandleDrag(),
          onPanCancel: _endHandleDrag,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: ProfileBanner(config: _draft, height: _previewHeight),
              ),
              IgnorePointer(
                child: CustomPaint(
                  painter: _BannerHandlesPainter(
                    lights: _lights,
                    colors: _colors,
                    activeLightIndex:
                        _draggingLightIndex ?? _selectedColorIndex,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  void _setColor(int index, Color color) {
    if (!mounted) return;
    final colors = List<Color>.from(_colors);
    colors[index] = color;
    setState(() => _colors = colors);
  }

  Future<void> _editColor(int index) async {
    final original = _colors[index];
    final color = await showDialog<Color>(
      context: context,
      builder: (dialogContext) {
        var draft = _colors[index];
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: GE.bgDeep,
            title: Text('Цвет ${index + 1}', style: TextStyle(color: GE.text)),
            content: SizedBox(
              width: 340,
              child: ColorPickerPanel(
                initial: draft,
                onChanged: (value) {
                  draft = value;
                  _setColor(index, value);
                  setDialogState(() {});
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, draft),
                child: const Text('Готово'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted) return;
    if (color != null) {
      _setColor(index, color);
    } else {
      _setColor(index, original);
    }
  }

  Future<void> _editBackgroundColor() async {
    final original = _backgroundColor;
    final color = await showDialog<Color>(
      context: context,
      builder: (dialogContext) {
        var draft = _backgroundColor;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: GE.bgDeep,
            title: Text('Цвет фона', style: TextStyle(color: GE.text)),
            content: SizedBox(
              width: 340,
              child: ColorPickerPanel(
                initial: draft,
                onChanged: (value) {
                  draft = value;
                  setState(() => _backgroundColor = value);
                  setDialogState(() {});
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, draft),
                child: const Text('Готово'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted) return;
    setState(() => _backgroundColor = color ?? original);
  }

  void _addColor() {
    if (_colors.length >= 10) return;
    final color = Color.lerp(_colors.last, GE.primary, 0.5) ?? _colors.last;
    final insertAt = _colors.length;
    final lights = List<ProfileBannerLight>.from(_lights)
      ..insert(insertAt, _newLight(insertAt, insertAt));
    setState(() {
      _colors = [..._colors, color];
      _lights = _reindexLights(lights, _colors.length);
    });
  }

  void _removeColor(int index) {
    if (_colors.length <= 1) return;
    final lights = List<ProfileBannerLight>.from(_lights)..removeAt(index);
    final colors = List<Color>.from(_colors)..removeAt(index);
    final selected = _selectedColorIndex > index
        ? _selectedColorIndex - 1
        : _selectedColorIndex.clamp(0, colors.length - 1).toInt();
    setState(() {
      _colors = colors;
      _selectedColorIndex = selected;
      _lights = _reindexLights(lights, colors.length);
    });
  }

  ProfileBannerLight _newLight(int colorIndex, int sequence) {
    const positions = [
      Offset(0.24, 0.0),
      Offset(1.0, 0.68),
      Offset(0.72, 1.0),
      Offset(0.0, 0.42),
      Offset(0.52, 0.0),
      Offset(1.0, 0.25),
      Offset(0.28, 1.0),
      Offset(0.0, 0.78),
      Offset(0.76, 0.0),
      Offset(1.0, 0.86),
    ];
    final slot = sequence % positions.length;
    return ProfileBannerLight(
      colorIndex: colorIndex,
      position: positions[slot],
      strength: 0.7,
    );
  }

  void _updateLight(int index, ProfileBannerLight light) {
    final lights = List<ProfileBannerLight>.from(_lights);
    lights[index] = light.copyWith(colorIndex: index);
    setState(() => _lights = lights);
  }

  void _selectColor(int index) {
    if (index < 0 || index >= _colors.length) return;
    setState(() => _selectedColorIndex = index);
  }

  Widget _buildColorStrip() {
    final hasAddButton = _colors.length < 10;
    return SizedBox(
      height: 66,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _colors.length + (hasAddButton ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index == _colors.length) {
            return OutlinedButton.icon(
              onPressed: _addColor,
              icon: const Icon(CupertinoIcons.plus, size: 17),
              label: const Text('Добавить'),
            );
          }
          final selected = index == _selectedColorIndex;
          return GestureDetector(
            onTap: () => _selectColor(index),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 58,
              padding: const EdgeInsets.symmetric(vertical: 5),
              decoration: BoxDecoration(
                color: GE.surface.withValues(alpha: selected ? 0.95 : 0.62),
                borderRadius: BorderRadius.circular(GE.radiusSm),
                border: Border.all(
                  color: selected ? _colors[index] : GE.glassBorder,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: _colors[index],
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${index + 1}',
                    style: TextStyle(
                      color: selected ? GE.text : GE.sub,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSelectedColorPanel() {
    final index = _selectedColorIndex.clamp(0, _colors.length - 1).toInt();
    final light = _lights[index];
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
      decoration: BoxDecoration(
        color: GE.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(GE.radiusMd),
        border: Border.all(color: GE.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: _colors[index],
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Цвет ${index + 1} · точка света ${index + 1}',
                  style: TextStyle(color: GE.text, fontWeight: FontWeight.w800),
                ),
              ),
              if (_colors.length > 1)
                IconButton(
                  tooltip: 'Удалить цвет и его точку света',
                  onPressed: () => _removeColor(index),
                  icon: Icon(
                    CupertinoIcons.minus_circle,
                    color: GE.sub,
                    size: 20,
                  ),
                ),
              TextButton.icon(
                onPressed: () => _editColor(index),
                icon: const Icon(CupertinoIcons.paintbrush, size: 16),
                label: const Text('Цвет'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('Сила', style: TextStyle(color: GE.sub, fontSize: 12)),
              const Spacer(),
              Text(
                '${(light.strength * 100).round()}%',
                style: TextStyle(color: GE.text, fontSize: 12),
              ),
            ],
          ),
          Slider(
            value: light.strength.clamp(0.0, 1.0),
            onChanged: (value) =>
                _updateLight(index, light.copyWith(strength: value)),
          ),
          Text(
            'Сила задаёт радиус и яркость мягкого заполнения.',
            style: TextStyle(color: GE.sub, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildBackgroundColorPanel() => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
    decoration: BoxDecoration(
      color: GE.surface.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(GE.radiusMd),
      border: Border.all(color: GE.glassBorder),
    ),
    child: Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: _backgroundColor,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Фон баннера',
                style: TextStyle(color: GE.text, fontWeight: FontWeight.w800),
              ),
              Text(
                'Базовый цвет под всеми источниками света',
                style: TextStyle(color: GE.sub, fontSize: 11),
              ),
            ],
          ),
        ),
        TextButton.icon(
          onPressed: _editBackgroundColor,
          icon: const Icon(CupertinoIcons.paintbrush, size: 16),
          label: const Text('Цвет'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: Material(
          color: GE.bgDeep,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(GE.radiusLg),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: GE.sub.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Редактор света',
                        style: TextStyle(
                          color: GE.text,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(CupertinoIcons.xmark, color: GE.sub),
                    ),
                  ],
                ),
                Text(
                  'Каждый цвет — отдельный источник света. Настраивай точки прямо на баннере.',
                  style: TextStyle(color: GE.sub, fontSize: 12),
                ),
                const SizedBox(height: 12),
                _buildInteractivePreview(),
                const SizedBox(height: 10),
                Text(
                  'Цвета и источники',
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Точки находятся на краю. Перетаскивай их вдоль периметра, а силу меняй ниже.',
                  style: TextStyle(color: GE.sub, fontSize: 12),
                ),
                const SizedBox(height: 10),
                _buildBackgroundColorPanel(),
                const SizedBox(height: 10),
                _buildColorStrip(),
                const SizedBox(height: 10),
                _buildSelectedColorPanel(),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(
                          context,
                          const ProfileBannerEditResult.clear(),
                        ),
                        child: const Text('По умолчанию'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(
                          context,
                          ProfileBannerEditResult.save(_draft),
                        ),
                        child: const Text('Сохранить'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BannerHandlesPainter extends CustomPainter {
  final List<ProfileBannerLight> lights;
  final List<Color> colors;
  final int? activeLightIndex;

  const _BannerHandlesPainter({
    required this.lights,
    required this.colors,
    required this.activeLightIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (var index = 0; index < lights.length; index++) {
      final light = lights[index];
      final source = Offset(
        light.position.dx * size.width,
        light.position.dy * size.height,
      );
      final color =
          colors[light.colorIndex.clamp(0, colors.length - 1).toInt()];
      _drawHandle(
        canvas,
        source,
        color: color,
        borderColor: Colors.white,
        active: activeLightIndex == index,
        index: index,
      );
    }
  }

  void _drawHandle(
    Canvas canvas,
    Offset center, {
    required Color color,
    required Color borderColor,
    required bool active,
    required int? index,
  }) {
    final outerRadius = active ? 13.0 : 11.0;
    canvas.drawCircle(
      center,
      outerRadius,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.38)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      center,
      outerRadius - 2,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      center,
      outerRadius - 2,
      Paint()
        ..color = borderColor
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );

    if (index != null) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${index + 1}',
          style: const TextStyle(
            color: Colors.black,
            fontSize: 10,
            fontWeight: FontWeight.w900,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        center - Offset(textPainter.width / 2, textPainter.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BannerHandlesPainter oldDelegate) => true;
}
