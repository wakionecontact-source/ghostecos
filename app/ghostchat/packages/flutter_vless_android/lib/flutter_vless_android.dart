// Copyright (c) 2024-2026 13FOX Studio / tfox.dev.
// SPDX-License-Identifier: MIT

import 'package:flutter_vless_platform_interface/flutter_vless_platform_interface.dart';

/// Android implementation of [VlessPlatform] using MethodChannel.
class FlutterVlessAndroid extends VlessMethodChannelAdapter {
  /// Registers this class as the platform implementation.
  /// This is called automatically by Flutter's plugin registry.
  static void registerWith() {
    VlessPlatform.instance = FlutterVlessAndroid();
  }
}
