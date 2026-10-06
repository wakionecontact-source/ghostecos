import 'dart:io' show Platform;

import 'package:local_auth/local_auth.dart';

class BiometricAuthService {
  BiometricAuthService._();

  static final BiometricAuthService instance = BiometricAuthService._();

  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> isAvailable() async {
    if (!Platform.isAndroid) return false;
    try {
      if (!await _auth.canCheckBiometrics) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticate() async {
    if (!Platform.isAndroid) return false;
    return _auth.authenticate(
      localizedReason: 'Подтвердите вход в GhostChat',
      biometricOnly: true,
      persistAcrossBackgrounding: true,
    );
  }
}
