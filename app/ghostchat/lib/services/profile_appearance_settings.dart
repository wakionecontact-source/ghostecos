import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ProfileMusicWidgetStyle { card, pill }

/// Appearance choices that belong specifically to the profile surface.
/// Keeping this separate from ThemeService prevents profile-only controls from
/// causing a full palette rebuild.
class ProfileAppearanceSettings {
  ProfileAppearanceSettings._();

  static final ProfileAppearanceSettings instance =
      ProfileAppearanceSettings._();

  static const _musicWidgetStyleKey = 'profile_music_widget_style_v1';

  bool _loaded = false;
  final ValueNotifier<ProfileMusicWidgetStyle> musicWidgetStyleNotifier =
      ValueNotifier(ProfileMusicWidgetStyle.card);

  ProfileMusicWidgetStyle get musicWidgetStyle =>
      musicWidgetStyleNotifier.value;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_musicWidgetStyleKey);
      final style = ProfileMusicWidgetStyle.values
          .cast<ProfileMusicWidgetStyle?>()
          .firstWhere((value) => value?.name == raw, orElse: () => null);
      if (style != null) musicWidgetStyleNotifier.value = style;
    } catch (_) {
      // The card is a safe default if preferences are temporarily unavailable.
    }
  }

  Future<void> setMusicWidgetStyle(ProfileMusicWidgetStyle style) async {
    musicWidgetStyleNotifier.value = style;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_musicWidgetStyleKey, style.name);
    } catch (_) {
      // Keep the live choice even if persistence fails for this session.
    }
  }
}
