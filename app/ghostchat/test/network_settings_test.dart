import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ghost/services/network_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('connection checks default to on and persist the user choice', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = NetworkSettings.instance;

    await settings.load();
    expect(settings.checkConnectionNotifier.value, isTrue);

    await settings.setCheckConnection(false);
    expect(settings.checkConnectionNotifier.value, isFalse);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('net_check_connection_v1'), isFalse);
  });
}
