import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/global_audio_player.dart';
import '../services/profile_appearance_settings.dart';
import '../theme.dart';
import 'profile_banner.dart';

/// Reuses the profile banner as a compact surface and mirrors its visual flow
/// for the music block, including the multi-light renderer.
class MirroredProfileBanner extends StatelessWidget {
  final ProfileBannerConfig? banner;
  final double height;

  const MirroredProfileBanner({
    super.key,
    required this.banner,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    final config = banner;
    if (config == null) {
      return ColoredBox(color: GE.surface);
    }
    return IgnorePointer(
      child: Transform.scale(
        scaleX: -1,
        scaleY: -1,
        child: ProfileBanner(config: config, height: height),
      ),
    );
  }
}

/// Compact profile playlist entry. The entire card is the play/open target;
/// editing and removal live in the playlist screen, not on this widget.
class ProfileMusicPlayer extends StatelessWidget {
  final List<Map<String, dynamic>> tracks;
  final ProfileBannerConfig? banner;
  final VoidCallback? onTap;
  final String? sourceProfileUsername;

  const ProfileMusicPlayer({
    super.key,
    required this.tracks,
    this.banner,
    this.onTap,
    this.sourceProfileUsername,
  });

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: Listenable.merge([
        GlobalAudioPlayer.instance,
        ProfileAppearanceSettings.instance.musicWidgetStyleNotifier,
      ]),
      builder: (context, _) {
        final style = ProfileAppearanceSettings.instance.musicWidgetStyle;
        return style == ProfileMusicWidgetStyle.pill
            ? _buildPill()
            : _buildCard();
      },
    );
  }

  Widget _buildCard() {
    final first = tracks.first;
    final title = _text(first['name'], 'Музыка профиля');
    final artist = _text(first['artist'], 'Неизвестный исполнитель');
    final cover = _text(first['cover_url'], '');
    final radius = (GE.radiusLg * 0.82).clamp(16.0, 28.0).toDouble();
    final player = GlobalAudioPlayer.instance;
    final active = _key(player.currentTrack) == _key(first) && player.isPlaying;
    return SizedBox(
      height: 72,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(radius),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Keep an opaque base beneath the mirrored banner. This
                // prevents the profile page from showing through the widget
                // even when a saved banner colour contains alpha.
                ColoredBox(color: GE.surface),
                _mirroredBannerBackground(72),
                ColoredBox(color: Colors.black.withValues(alpha: 0.14)),
                Padding(
                  padding: const EdgeInsets.all(7),
                  child: SizedBox(
                    height: 58,
                    child: Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: onTap,
                            borderRadius: BorderRadius.circular(12),
                            child: Row(
                              children: [
                                _cover(cover, radius * 0.52, size: 50),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: GE.text,
                                          fontSize: 14.5,
                                          fontWeight: FontWeight.w700,
                                          decoration: TextDecoration.none,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: GE.text.withValues(
                                            alpha: 0.78,
                                          ),
                                          fontSize: 11.5,
                                          decoration: TextDecoration.none,
                                        ),
                                      ),
                                      if (tracks.length > 1)
                                        Text(
                                          '${tracks.length} трека в профиле',
                                          style: TextStyle(
                                            color: GE.text.withValues(
                                              alpha: 0.58,
                                            ),
                                            fontSize: 10,
                                            decoration: TextDecoration.none,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: active ? 'Пауза' : 'Воспроизвести',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          onPressed: () => _playOrToggle(first),
                          icon: Icon(
                            active
                                ? CupertinoIcons.pause_fill
                                : CupertinoIcons.play_fill,
                            color: GE.text.withValues(alpha: 0.86),
                            size: 18,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPill() {
    final first = tracks.first;
    final title = _text(first['name'], 'Музыка профиля');
    final artist = _text(first['artist'], 'Неизвестный исполнитель');
    final player = GlobalAudioPlayer.instance;
    final active = _key(player.currentTrack) == _key(first) && player.isPlaying;
    final radius = (GE.radiusMd * 1.2).clamp(14.0, 22.0).toDouble();
    return SizedBox(
      height: 32,
      child: Align(
        alignment: Alignment.center,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(radius),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: GE.surface),
                  _mirroredBannerBackground(32),
                  ColoredBox(color: Colors.black.withValues(alpha: 0.14)),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: active ? 'Пауза' : 'Воспроизвести',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          onPressed: () => _playOrToggle(first),
                          icon: Icon(
                            active
                                ? CupertinoIcons.pause_fill
                                : CupertinoIcons.play_fill,
                            color: GE.text.withValues(alpha: 0.92),
                            size: 15,
                          ),
                        ),
                        const SizedBox(width: 2),
                        InkWell(
                          onTap: onTap,
                          borderRadius: BorderRadius.circular(10),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 250,
                                  ),
                                  child: Text(
                                    '$artist — $title',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: GE.text,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      decoration: TextDecoration.none,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  CupertinoIcons.chevron_right,
                                  color: GE.text.withValues(alpha: 0.72),
                                  size: 14,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cover(String url, double radius, {double size = 70}) {
    final full = url.isEmpty ? null : _absolute(url);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: full == null
            ? _fallback()
            : Image.network(
                full,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _fallback(),
              ),
      ),
    );
  }

  Widget _fallback() => ColoredBox(
    color: GE.surface,
    child: Icon(CupertinoIcons.music_note_2, color: GE.text, size: 28),
  );

  Widget _mirroredBannerBackground(double height) {
    return MirroredProfileBanner(banner: banner, height: height);
  }

  String _absolute(String value) =>
      value.startsWith('http') ? value : '${GE.baseUrl}$value';

  Future<void> _playOrToggle(Map<String, dynamic> first) async {
    final player = GlobalAudioPlayer.instance;
    if (_key(player.currentTrack) == _key(first)) {
      await player.toggle();
    } else {
      await player.playQueue(_withSource(tracks));
    }
  }

  List<Map<String, dynamic>> _withSource(List<Map<String, dynamic>> source) =>
      source
          .map(
            (track) => {
              ...track,
              '_audio_source': 'profile_music',
              if (sourceProfileUsername != null)
                '_audio_profile_username': sourceProfileUsername,
            },
          )
          .toList();

  String _text(Object? value, String fallback) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  String _key(Map<String, dynamic>? track) => track == null
      ? ''
      : '${track['source'] ?? 'local'}:${track['track_id'] ?? track['url'] ?? track['name']}';
}
