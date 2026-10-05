part of 'global_audio_player.dart';

/// A quiet mini-player that stays out of the chat layout. Tapping it opens the
/// full controls instead of putting every control into a permanently tall bar.
class _ModernFloatingAudioPlayer extends StatefulWidget {
  final GlobalAudioPlayer player;
  final GlobalAudioPlayerSourceOpener? onOpenSource;

  const _ModernFloatingAudioPlayer({required this.player, this.onOpenSource});

  @override
  State<_ModernFloatingAudioPlayer> createState() =>
      _ModernFloatingAudioPlayerState();
}

class _ModernFloatingAudioPlayerState
    extends State<_ModernFloatingAudioPlayer> {
  double? _dragDelta;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final top = player.positionNotifier.value == AudioPlayerPosition.top;
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final isWide = width >= 720;
        final horizontalMargin = (width * 0.035).clamp(12.0, 24.0);
        final playerWidth = math.min(
          560.0,
          math.max(0.0, width - horizontalMargin * 2),
        );

        // The host is above the navigator, so it must reserve the chrome
        // corridor itself. These values scale gently with the window instead
        // of pinning the card to one phone's coordinates.
        // The top position must clear both the translucent app bar and the
        // search field used by Rooms/Chats. Keep it responsive on tablets,
        // but never put the player over that first interactive row.
        final topHeader = (height * 0.13).clamp(116.0, 156.0);
        final bottomNavigation = isWide
            ? (height * 0.09).clamp(78.0, 104.0)
            : (height * 0.105).clamp(92.0, 126.0);
        final quickActions = isWide ? 0.0 : (height * 0.055).clamp(54.0, 76.0);
        final keyboard = media.viewInsets.bottom;
        final bottomChrome = keyboard > 0
            // Keep the card above the chat composer while the keyboard is
            // open; the bottom navigation is hidden by the keyboard then.
            ? keyboard + 76.0
            : bottomNavigation + quickActions + 12.0;
        final topOffset = media.viewPadding.top + topHeader;
        final bottom = media.viewPadding.bottom + bottomChrome;
        // The mini surface is intentionally not measured here: its height can
        // change while metadata arrives. This conservative estimate is only
        // used to clamp a long-press drag and to choose the snap side; the
        // actual card keeps its natural height.
        final estimatedCardHeight =
            player.visualStyle == AudioPlayerVisualStyle.compact ? 82.0 : 92.0;
        final bottomTop = math.max(
          topOffset,
          height - bottom - estimatedCardHeight,
        );
        final anchoredTop = top ? topOffset : bottomTop;
        final minDelta = topOffset - anchoredTop;
        final maxDelta = bottomTop - anchoredTop;
        final delta = (_dragDelta ?? 0.0).clamp(minDelta, maxDelta).toDouble();

        return AnimatedPadding(
          duration: _dragging
              ? Duration.zero
              : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.fromLTRB(
            horizontalMargin,
            top ? topOffset : 0,
            horizontalMargin,
            top ? 0 : bottom,
          ),
          child: Align(
            alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPressStart: (_) {
                setState(() {
                  _dragging = true;
                  _dragDelta = 0;
                });
              },
              onLongPressMoveUpdate: (details) {
                if (!_dragging) return;
                setState(() {
                  _dragDelta = details.offsetFromOrigin.dy
                      .clamp(minDelta, maxDelta)
                      .toDouble();
                });
              },
              onLongPressEnd: (_) {
                final currentTop = anchoredTop + delta;
                final next = currentTop + estimatedCardHeight / 2 < height / 2
                    ? AudioPlayerPosition.top
                    : AudioPlayerPosition.bottom;
                player.setPosition(next);
                setState(() {
                  _dragging = false;
                  _dragDelta = null;
                });
              },
              child: Transform.translate(
                offset: Offset(0, _dragging ? delta : 0),
                child: SizedBox(
                  width: playerWidth,
                  child: _ModernMiniAudioPlayer(
                    player: player,
                    onOpenSource: widget.onOpenSource,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ModernMiniAudioPlayer extends StatelessWidget {
  final GlobalAudioPlayer player;
  final GlobalAudioPlayerSourceOpener? onOpenSource;

  const _ModernMiniAudioPlayer({required this.player, this.onOpenSource});

  @override
  Widget build(BuildContext context) {
    final track = player.currentTrack!;
    final compact = player.visualStyle == AudioPlayerVisualStyle.compact;
    final failed =
        player.error != null && !player.isLoading && !player.isPlaying;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openExpanded(context),
        borderRadius: BorderRadius.circular(compact ? 18 : 22),
        child: GlassCard(
          radius: compact ? 18 : 22,
          padding: EdgeInsets.fromLTRB(
            compact ? 8 : 10,
            compact ? 7 : 9,
            compact ? 8 : 10,
            compact ? 6 : 7,
          ),
          fillOverride: GE.surface.withValues(alpha: compact ? 0.92 : 0.84),
          blurOverride: compact ? 20 : 26,
          ignoreSurfaceToggle: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _modernCover(
                    track['cover_url'] as String?,
                    compact ? 42 : 48,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _modernAudioText(track['name'], 'Музыка'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: GE.text,
                            fontSize: compact ? 13 : 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          failed
                              ? 'Не удалось загрузить звук'
                              : _modernAudioText(
                                  track['artist'],
                                  'Неизвестный исполнитель',
                                ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: failed ? GE.red : GE.sub,
                            fontSize: compact ? 11 : 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _modernMiniButton(
                    player.isLoading
                        ? CupertinoIcons.hourglass
                        : player.isPlaying
                        ? CupertinoIcons.pause_fill
                        : CupertinoIcons.play_fill,
                    player.isLoading ? () {} : () => unawaited(player.toggle()),
                    GE.primary,
                    player.isPlaying ? 'Пауза' : 'Воспроизвести',
                  ),
                  _modernMiniButton(
                    CupertinoIcons.forward_fill,
                    () => unawaited(player.next()),
                    GE.sub,
                    'Следующий трек',
                  ),
                  _modernMiniButton(
                    CupertinoIcons.clear_circled,
                    () => unawaited(player.stop(clearQueue: true)),
                    GE.sub,
                    'Убрать плеер',
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: compact ? 3 : 4,
                  value: _modernAudioProgress(player),
                  backgroundColor: GE.sub.withValues(alpha: 0.18),
                  valueColor: AlwaysStoppedAnimation(
                    failed ? GE.red : GE.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openExpanded(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _ModernNowPlayingSheet(player: player, onOpenSource: onOpenSource),
    );
  }

  Widget _modernMiniButton(
    IconData icon,
    VoidCallback onPressed,
    Color color,
    String tooltip,
  ) {
    return SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
        icon: Icon(icon, color: color, size: 17),
      ),
    );
  }
}

class _ModernNowPlayingSheet extends StatelessWidget {
  final GlobalAudioPlayer player;
  final GlobalAudioPlayerSourceOpener? onOpenSource;

  const _ModernNowPlayingSheet({required this.player, this.onOpenSource});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        decoration: BoxDecoration(
          color: GE.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          border: Border.all(color: GE.glassBorder),
        ),
        child: SafeArea(
          top: false,
          child: AnimatedBuilder(
            animation: Listenable.merge([player, player.positionNotifier]),
            builder: (context, _) {
              final track = player.currentTrack;
              if (track == null) return const SizedBox.shrink();
              final total = player.duration.inMilliseconds.toDouble();
              final failed =
                  player.error != null &&
                  !player.isLoading &&
                  !player.isPlaying;
              final canOpenSource =
                  onOpenSource != null &&
                  track['_audio_source'] == 'profile_music';
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
                child: Column(
                  children: [
                    Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: GE.sub.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        tooltip: 'Закрыть',
                        onPressed: () => Navigator.pop(context),
                        icon: Icon(CupertinoIcons.xmark, color: GE.sub),
                      ),
                    ),
                    _modernCover(track['cover_url'] as String?, 210),
                    const SizedBox(height: 18),
                    Text(
                      _modernAudioText(track['name'], 'Музыка'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 23,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      failed
                          ? 'Не удалось загрузить звук'
                          : _modernAudioText(
                              track['artist'],
                              'Неизвестный исполнитель',
                            ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: failed ? GE.red : GE.sub),
                    ),
                    const SizedBox(height: 19),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        activeTrackColor: failed ? GE.red : GE.primary,
                        inactiveTrackColor: GE.sub.withValues(alpha: 0.22),
                        thumbColor: failed ? GE.red : GE.primary,
                      ),
                      child: Slider(
                        value: _modernAudioProgress(player),
                        min: 0,
                        max: 1,
                        onChanged: total <= 0
                            ? null
                            : (value) => player.previewSeek(
                                Duration(milliseconds: (total * value).round()),
                              ),
                        onChangeEnd: total <= 0
                            ? null
                            : (value) => unawaited(
                                player.seek(
                                  Duration(
                                    milliseconds: (total * value).round(),
                                  ),
                                ),
                              ),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _modernAudioTime(player.position),
                          style: TextStyle(color: GE.sub, fontSize: 11),
                        ),
                        Text(
                          _modernAudioTime(player.duration),
                          style: TextStyle(color: GE.sub, fontSize: 11),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _modernSheetButton(
                          CupertinoIcons.shuffle,
                          () => player.setShuffle(!player.shuffle),
                          player.shuffle ? GE.primary : GE.sub,
                          'Перемешать',
                        ),
                        const SizedBox(width: 10),
                        _modernSheetButton(
                          CupertinoIcons.backward_fill,
                          () => unawaited(player.previous()),
                          GE.text,
                          'Предыдущий трек',
                        ),
                        const SizedBox(width: 10),
                        _modernSheetButton(
                          player.isLoading
                              ? CupertinoIcons.hourglass
                              : player.isPlaying
                              ? CupertinoIcons.pause_fill
                              : CupertinoIcons.play_fill,
                          player.isLoading
                              ? () {}
                              : () => unawaited(player.toggle()),
                          GE.primary,
                          player.isPlaying ? 'Пауза' : 'Воспроизвести',
                          large: true,
                        ),
                        const SizedBox(width: 10),
                        _modernSheetButton(
                          CupertinoIcons.forward_fill,
                          () => unawaited(player.next()),
                          GE.text,
                          'Следующий трек',
                        ),
                        const SizedBox(width: 10),
                        _modernSheetButton(
                          CupertinoIcons.repeat,
                          player.cycleRepeat,
                          player.repeatMode == AudioRepeatMode.off
                              ? GE.sub
                              : GE.primary,
                          'Повтор',
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    GlassCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            player.isMuted || player.volume <= 0.01
                                ? CupertinoIcons.volume_off
                                : CupertinoIcons.volume_up,
                            color: GE.sub,
                            size: 18,
                          ),
                          Expanded(
                            child: Slider(
                              value: player.volume,
                              min: 0,
                              max: 1,
                              onChanged: player.setVolume,
                            ),
                          ),
                          IconButton(
                            tooltip: player.isMuted
                                ? 'Включить звук'
                                : 'Выключить звук',
                            onPressed: player.toggleMute,
                            icon: Icon(
                              player.isMuted
                                  ? CupertinoIcons.volume_off
                                  : CupertinoIcons.volume_up,
                              color: player.isMuted ? GE.sub : GE.primary,
                              size: 18,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (canOpenSource) ...[
                      const SizedBox(height: 10),
                      TextButton.icon(
                        onPressed: () => onOpenSource!(context, player),
                        icon: const Icon(CupertinoIcons.music_note_2),
                        label: const Text('Открыть музыку профиля'),
                      ),
                    ],
                    if (player.queue.length > 1) ...[
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Очередь',
                          style: TextStyle(
                            color: GE.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (var index = 0; index < player.queue.length; index++)
                        _modernQueueTile(player.queue[index]),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _modernQueueTile(Map<String, dynamic> track) {
    final active =
        _modernTrackKey(track) == _modernTrackKey(player.currentTrack);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _modernCover(track['cover_url'] as String?, 42),
      title: Text(
        _modernAudioText(track['name'], 'Музыка'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: active ? GE.primary : GE.text,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: Text(
        _modernAudioText(track['artist'], 'Неизвестный исполнитель'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: active && player.isPlaying ? 'Пауза' : 'Воспроизвести',
        onPressed: () {
          if (active) {
            unawaited(player.toggle());
          } else {
            unawaited(player.playTrack(track));
          }
        },
        icon: Icon(
          active && player.isPlaying
              ? CupertinoIcons.pause_fill
              : CupertinoIcons.play_fill,
          color: active ? GE.primary : GE.sub,
        ),
      ),
      onTap: () => unawaited(player.playTrack(track)),
    );
  }

  Widget _modernSheetButton(
    IconData icon,
    VoidCallback onPressed,
    Color color,
    String tooltip, {
    bool large = false,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: color, size: large ? 34 : 20),
      style: large
          ? IconButton.styleFrom(
              backgroundColor: GE.primary.withValues(alpha: 0.16),
              minimumSize: const Size(64, 64),
            )
          : null,
    );
  }
}

Widget _modernCover(String? value, double size) {
  final url = value == null || value.isEmpty
      ? null
      : value.startsWith('http')
      ? value
      : '${GE.baseUrl}$value';
  return ClipRRect(
    borderRadius: BorderRadius.circular(size * 0.2),
    child: SizedBox(
      width: size,
      height: size,
      child: url == null
          ? ColoredBox(
              color: GE.primary.withValues(alpha: 0.16),
              child: Icon(
                CupertinoIcons.music_note_2,
                color: GE.primary,
                size: size * 0.42,
              ),
            )
          : Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => ColoredBox(
                color: GE.primary.withValues(alpha: 0.16),
                child: Icon(
                  CupertinoIcons.music_note_2,
                  color: GE.primary,
                  size: size * 0.42,
                ),
              ),
            ),
    ),
  );
}

double _modernAudioProgress(GlobalAudioPlayer player) {
  final total = player.duration.inMilliseconds;
  if (total <= 0) return 0;
  return (player.position.inMilliseconds / total).clamp(0.0, 1.0).toDouble();
}

String _modernAudioText(Object? value, String fallback) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

String _modernAudioTime(Duration value) {
  final totalSeconds = value.inSeconds.clamp(0, 99 * 60 * 60);
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  if (minutes >= 60) {
    final hours = minutes ~/ 60;
    final restMinutes = minutes % 60;
    return '$hours:${restMinutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _modernTrackKey(Map<String, dynamic>? track) => track == null
    ? ''
    : '${track['source'] ?? 'local'}:${track['track_id'] ?? track['url'] ?? track['name']}';
