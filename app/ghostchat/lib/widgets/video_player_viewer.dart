import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../theme.dart';

/// Полноэкранный встроенный видеоплеер GhostChat.
///
/// Видео остаётся внутри приложения: это важно для зашифрованных вложений,
/// которые не должны передаваться внешнему проигрывателю.
class GhostVideoViewer extends StatefulWidget {
  final String path;
  final String? fallbackPath;
  final bool deleteWhenClosed;
  final String? title;

  const GhostVideoViewer({
    super.key,
    required this.path,
    this.fallbackPath,
    this.deleteWhenClosed = false,
    this.title,
  });

  @override
  State<GhostVideoViewer> createState() => _GhostVideoViewerState();
}

class _GhostVideoViewerState extends State<GhostVideoViewer>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  Timer? _hideControlsTimer;
  bool _showControls = true;
  bool _failed = false;
  String? _error;
  double _dragY = 0;
  bool _resumeAfterLifecycle = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    unawaited(_createController());
  }

  Future<void> _createController() async {
    final candidates = <String>[widget.path];
    final fallback = widget.fallbackPath;
    if (fallback != null && fallback != widget.path) candidates.add(fallback);
    Object? lastError;
    for (final path in candidates) {
      try {
        final file = File(path);
        if (!await file.exists() || await file.length() == 0) {
          lastError = StateError('Файл видео отсутствует');
          continue;
        }
        // На части Xiaomi/MediaTek TextureView отдаёт рваные кадры:
        // скриншот содержит горизонтальные полосы и куски соседних кадров.
        // SurfaceView обходит этот дефект аппаратного texture-композитинга.
        final controller = VideoPlayerController.file(
          file,
          viewType: VideoViewType.platformView,
        );
        _controller = controller;
        controller.addListener(_onControllerChanged);
        await controller.initialize();
        if (!mounted) {
          await controller.dispose();
          return;
        }
        await controller.setLooping(false);
        if (!mounted) {
          await controller.dispose();
          return;
        }
        setState(() {});
        unawaited(controller.play());
        _scheduleHideControls();
        return;
      } catch (error) {
        lastError = error;
        final controller = _controller;
        _controller = null;
        controller?.removeListener(_onControllerChanged);
        if (controller != null) await controller.dispose();
      }
    }
    if (!mounted) return;
    setState(() {
      _failed = true;
      _error = lastError?.toString();
    });
    _cancelHideControls();
  }

  void _onControllerChanged() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    if (controller.value.isCompleted && !_showControls) {
      setState(() => _showControls = true);
      _cancelHideControls();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.resumed) {
      if (_resumeAfterLifecycle) {
        _resumeAfterLifecycle = false;
        unawaited(controller.play());
        _scheduleHideControls();
      }
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _resumeAfterLifecycle = controller.value.isPlaying;
      _cancelHideControls();
      unawaited(controller.pause());
      if (mounted) setState(() => _showControls = true);
    }
  }

  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    final controller = _controller;
    if (controller == null || !controller.value.isPlaying) return;
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _controller?.value.isPlaying == true) {
        setState(() => _showControls = false);
      }
    });
  }

  void _cancelHideControls() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = null;
  }

  void _toggleControls() {
    if (_showControls) {
      _cancelHideControls();
      setState(() => _showControls = false);
    } else {
      setState(() => _showControls = true);
      _scheduleHideControls();
    }
  }

  void _togglePlayback() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isCompleted) {
      unawaited(controller.seekTo(Duration.zero));
      unawaited(controller.play());
      _scheduleHideControls();
    } else if (controller.value.isPlaying) {
      unawaited(controller.pause());
      _cancelHideControls();
      setState(() => _showControls = true);
    } else {
      unawaited(controller.play());
      _scheduleHideControls();
    }
  }

  void _seekBy(int seconds) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final value = controller.value;
    final target = value.position + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : target > value.duration
        ? value.duration
        : target;
    unawaited(controller.seekTo(clamped));
    setState(() => _showControls = true);
    _scheduleHideControls();
  }

  Future<void> _retry() async {
    final old = _controller;
    old?.removeListener(_onControllerChanged);
    await old?.dispose();
    if (!mounted) return;
    setState(() {
      _controller = null;
      _failed = false;
      _error = null;
    });
    unawaited(_createController());
  }

  Future<void> _deleteTemporaryFile() async {
    try {
      await File(widget.path).delete();
    } catch (_) {
      // The source may be a gallery file or may already have been removed.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelHideControls();
    final controller = _controller;
    controller?.removeListener(_onControllerChanged);
    if (controller != null) unawaited(controller.dispose());
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (widget.deleteWhenClosed) {
      unawaited(_deleteTemporaryFile());
    }
    super.dispose();
  }

  String _format(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final backgroundAlpha = (1 - (_dragY.abs() / 400)).clamp(0.0, 1.0);
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: backgroundAlpha),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        onDoubleTap: _togglePlayback,
        onVerticalDragUpdate: (details) {
          if (details.delta.dy.abs() > details.delta.dx.abs()) {
            setState(() => _dragY += details.delta.dy);
          }
        },
        onVerticalDragEnd: (_) {
          if (_dragY.abs() > 120) {
            Navigator.of(context).pop();
          } else if (mounted) {
            setState(() => _dragY = 0);
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: Transform.translate(
                offset: Offset(0, _dragY),
                child: controller == null
                    ? const CircularProgressIndicator(color: Colors.white)
                    : ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: controller,
                        builder: (_, value, _) {
                          if (_failed || value.hasError) {
                            return _errorView(value.errorDescription);
                          }
                          if (!value.isInitialized) {
                            return const CircularProgressIndicator(
                              color: Colors.white,
                            );
                          }
                          return _videoSurface(controller, value);
                        },
                      ),
              ),
            ),
            if (_showControls && controller != null)
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: controller,
                builder: (_, value, _) {
                  if (!value.isInitialized || value.hasError) {
                    return const SizedBox.shrink();
                  }
                  return _controls(controller, value);
                },
              ),
            if (controller != null)
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: controller,
                builder: (_, value, _) {
                  if (!value.isInitialized || !value.isBuffering) {
                    return const SizedBox.shrink();
                  }
                  return const Center(
                    child: SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    ),
                  );
                },
              ),
            if (_showControls) _topBar(),
          ],
        ),
      ),
    );
  }

  Widget _videoSurface(
    VideoPlayerController controller,
    VideoPlayerValue value,
  ) {
    final aspect = value.aspectRatio > 0 ? value.aspectRatio : 16 / 9;
    return LayoutBuilder(
      builder: (_, constraints) {
        final width = math.min(
          constraints.maxWidth,
          constraints.maxHeight * aspect,
        );
        final height = width / aspect;
        return SizedBox(
          width: width,
          height: height,
          child: VideoPlayer(controller),
        );
      },
    );
  }

  Widget _topBar() {
    final controller = _controller;
    return Positioned(
      top: MediaQuery.of(context).padding.top + 4,
      left: 8,
      right: 8,
      child: Row(
        children: [
          _roundButton(
            icon: CupertinoIcons.xmark,
            tooltip: 'Закрыть',
            onPressed: () => Navigator.of(context).pop(),
          ),
          if (widget.title != null) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          const Spacer(),
          if (controller != null)
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: controller,
              builder: (_, value, _) => _roundButton(
                icon: value.volume == 0
                    ? CupertinoIcons.volume_off
                    : CupertinoIcons.volume_up,
                tooltip: value.volume == 0 ? 'Включить звук' : 'Выключить звук',
                onPressed: _toggleMute,
              ),
            ),
        ],
      ),
    );
  }

  void _toggleMute() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    unawaited(controller.setVolume(controller.value.volume == 0 ? 1 : 0));
  }

  Widget _controls(VideoPlayerController controller, VideoPlayerValue value) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Color(0xE6000000)],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            12,
            44,
            12,
            MediaQuery.of(context).padding.bottom + 12,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _seekButton(
                    icon: CupertinoIcons.gobackward_10,
                    onPressed: () => _seekBy(-10),
                  ),
                  const SizedBox(width: 18),
                  _roundButton(
                    icon: value.isCompleted
                        ? CupertinoIcons.refresh
                        : value.isPlaying
                        ? CupertinoIcons.pause_fill
                        : CupertinoIcons.play_fill,
                    iconSize: 26,
                    onPressed: _togglePlayback,
                  ),
                  const SizedBox(width: 18),
                  _seekButton(
                    icon: CupertinoIcons.goforward_10,
                    onPressed: () => _seekBy(10),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    _format(value.position),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Listener(
                      onPointerDown: (_) => _cancelHideControls(),
                      onPointerUp: (_) => _scheduleHideControls(),
                      child: VideoProgressIndicator(
                        controller,
                        allowScrubbing: true,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        colors: VideoProgressColors(
                          playedColor: GE.primary,
                          bufferedColor: Colors.white54,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _format(value.duration),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required VoidCallback onPressed,
    String? tooltip,
    double iconSize = 22,
  }) {
    final button = SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, color: Colors.white, size: iconSize),
        style: IconButton.styleFrom(
          backgroundColor: Colors.black54,
          shape: const CircleBorder(),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }

  Widget _seekButton({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, color: Colors.white, size: 28),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black45,
        shape: const CircleBorder(),
      ),
    );
  }

  Widget _errorView(String? controllerError) {
    final details = _error ?? controllerError;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.exclamationmark_triangle,
            color: Colors.white70,
            size: 44,
          ),
          const SizedBox(height: 12),
          const Text(
            'Не удалось воспроизвести видео',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
          if (details?.isNotEmpty == true) ...[
            const SizedBox(height: 6),
            Text(
              details!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _retry,
            icon: const Icon(CupertinoIcons.refresh),
            label: const Text('Повторить'),
          ),
        ],
      ),
    );
  }
}
