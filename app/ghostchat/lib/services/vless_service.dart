import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_vless/flutter_vless.dart';

import '../core/storage/secure_store.dart';
import 'api_client.dart';
import 'ws_client.dart';

/// Android VLESS tunnel used by GhostChat's network settings.
///
/// The Android plugin is locally patched to route only this application's UID
/// into the VPN. That also covers native WebRTC sockets while leaving other
/// phone apps outside the tunnel.
class VlessService {
  VlessService._();

  static final VlessService instance = VlessService._();
  static const _profileKey = 'gc_vless_profile_v1';

  final ValueNotifier<VlessStatus> status = ValueNotifier<VlessStatus>(
    VlessStatus(),
  );

  late final FlutterVless _client = FlutterVless(
    onStatusChanged: _onStatusChanged,
  );

  bool _initialized = false;
  bool _lastTunnelConnected = false;

  void _onStatusChanged(VlessStatus next) {
    final connected = next.connectionState == VlessConnectionState.connected;
    status.value = next;
    final disconnected =
        next.connectionState == VlessConnectionState.disconnected;
    if (connected && !_lastTunnelConnected) {
      _lastTunnelConnected = true;
    } else if (disconnected && _lastTunnelConnected) {
      _lastTunnelConnected = false;
    } else {
      return;
    }
    ApiClient().applyProxySettings();
    WsClient.instance.reconnectForNetworkChange();
  }

  Future<void> initialize() async {
    if (!Platform.isAndroid || _initialized) return;
    await _client.initializeVless();
    _initialized = true;
  }

  Future<String?> loadSavedProfile() => SecureStore.I.read(_profileKey);

  Future<void> saveProfile(String shareLink) async {
    final value = shareLink.trim();
    if (value.isEmpty) {
      await SecureStore.I.delete(_profileKey);
      return;
    }
    _parseProfile(value).getFullConfiguration();
    await SecureStore.I.write(_profileKey, value);
  }

  Future<void> connect(String shareLink) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('VLESS VPN доступен только на Android.');
    }
    final value = shareLink.trim();
    final parsed = _parseProfile(value);
    final config = parsed.getFullConfiguration();

    await initialize();
    if (!await _client.requestPermission()) {
      throw const VlessPermissionDeniedException();
    }

    await SecureStore.I.write(_profileKey, value);
    await _client.startVless(
      remark: parsed.remark.trim().isEmpty ? 'GhostChat' : parsed.remark.trim(),
      config: config,
      blockedApps: const <String>[],
    );
  }

  Future<void> disconnect() async {
    await initialize();
    await _client.stopVless();
  }

  FlutterVlessURL _parseProfile(String value) {
    if (!value.startsWith('vless://')) {
      throw const FormatException('Expected a vless:// share link.');
    }
    return FlutterVless.parse(value);
  }
}

class VlessPermissionDeniedException implements Exception {
  const VlessPermissionDeniedException();
}
