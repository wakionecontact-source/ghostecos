import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ghost/services/sound_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sound switches default off and persist independently', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SoundSettings.instance;
    await settings.load();

    expect(settings.uiSoundsEnabledNotifier.value, isFalse);
    expect(
      settings.uiTapVariantNotifier.value,
      SoundSettings.defaultTapVariant,
    );
    expect(settings.notificationVariantNotifier.value, 0);
    expect(settings.callVariantNotifier.value, 0);
    expect(settings.successVariantNotifier.value, 0);
    expect(settings.warningVariantNotifier.value, 0);
    expect(settings.errorVariantNotifier.value, 0);
    expect(settings.notificationSoundsEnabledNotifier.value, isFalse);

    await settings.setUiSoundsEnabled(false);
    expect(settings.uiSoundsEnabledNotifier.value, isFalse);
    expect(settings.notificationSoundsEnabledNotifier.value, isFalse);

    await settings.setUiTapVariant(12);
    expect(settings.uiTapVariantNotifier.value, 9);
    await settings.setNotificationVariant(2);
    await settings.setCallVariant(1);
    await settings.setSuccessVariant(2);
    await settings.setWarningVariant(1);
    await settings.setErrorVariant(2);

    await settings.setNotificationSoundsEnabled(false);
    expect(settings.notificationSoundsEnabledNotifier.value, isFalse);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('ghost_sound_ui_enabled_v1'), isFalse);
    expect(prefs.getBool('ghost_sound_notifications_enabled_v1'), isFalse);
    expect(prefs.getInt('ghost_sound_ui_tap_variant_v1'), 9);
    expect(prefs.getInt('ghost_sound_notification_variant_v1'), 2);
    expect(prefs.getInt('ghost_sound_call_variant_v1'), 1);
    expect(prefs.getInt('ghost_sound_success_variant_v1'), 2);
    expect(prefs.getInt('ghost_sound_warning_variant_v1'), 1);
    expect(prefs.getInt('ghost_sound_error_variant_v1'), 2);
  });
}
