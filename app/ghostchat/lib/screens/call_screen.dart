import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../mesh_background.dart';
import '../models/call_media_route.dart';
import '../services/call_service.dart';
import '../services/api_client.dart';
import '../services/chat_repo.dart';
import '../services/profile_cache.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/call_widget.dart';
import '../widgets/glass.dart';
import '../widgets/emoji_text.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.peer, required this.displayName});

  final String peer;
  final String displayName;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  CallService get _calls => CallService.instance;

  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;
  bool _renderersReady = false;
  bool _closing = false;
  bool _allowPop = false;
  String? _avatarUrl;
  late String _avatarPeer;

  String get _currentPeer => _calls.state.value.peer ?? widget.peer;
  String get _currentDisplayName =>
      _currentPeer == widget.peer ? widget.displayName : '@$_currentPeer';

  @override
  void initState() {
    super.initState();
    _avatarPeer = widget.peer;
    _avatarUrl = ChatRepo.instance.getPeerAvatarCached(_avatarPeer);
    final cached = ProfileCache.instance.getProfileSync(_avatarPeer);
    _avatarUrl ??= cached?['avatar_url'] as String?;
    _calls.state.addListener(_onStateChanged);
    unawaited(_refreshPeerAvatar(_avatarPeer));
    unawaited(_initRenderers());
  }

  Future<void> _refreshPeerAvatar(String peer) async {
    try {
      final profile = await ApiClient().socGet(
        '/prof/${Uri.encodeComponent(peer)}',
      );
      if (profile is! Map) return;
      final remote = profile['avatar_url']?.toString().trim();
      if (remote == null || remote.isEmpty) return;
      // Do not rebuild or rewrite the cache when the server still has the
      // same avatar that was already rendered from memory.
      if (remote != _avatarUrl && mounted && _currentPeer == peer) {
        setState(() => _avatarUrl = remote);
      }
      if (remote != ChatRepo.instance.getPeerAvatarCached(peer)) {
        await ChatRepo.instance.cachePeerAvatar(peer, remote);
      }
      final cachedProfile = ProfileCache.instance.getProfileSync(peer);
      if (cachedProfile == null || cachedProfile['avatar_url'] != remote) {
        await ProfileCache.instance.setProfile(
          peer,
          Map<String, dynamic>.from(profile),
        );
      }
    } catch (_) {
      // A call must remain usable with the cached avatar while offline.
    }
  }

  Future<void> _initRenderers() async {
    final local = RTCVideoRenderer();
    final remote = RTCVideoRenderer();
    await local.initialize();
    await remote.initialize();
    if (!mounted) {
      await local.dispose();
      await remote.dispose();
      return;
    }
    _localRenderer = local;
    _remoteRenderer = remote;
    _renderersReady = true;
    _attachStreams(_calls.state.value);
    setState(() {});
  }

  void _attachStreams(CallSnapshot snapshot) {
    if (!_renderersReady) return;
    _localRenderer?.srcObject = snapshot.screenSharing
        ? snapshot.screenStream
        : snapshot.localStream;
    _remoteRenderer?.srcObject = snapshot.remoteStream;
  }

  void _onStateChanged() {
    final snapshot = _calls.state.value;
    _attachStreams(snapshot);
    final peer = snapshot.peer ?? widget.peer;
    if (peer != _avatarPeer) {
      _avatarPeer = peer;
      _avatarUrl = ChatRepo.instance.getPeerAvatarCached(peer);
      final cached = ProfileCache.instance.getProfileSync(peer);
      _avatarUrl ??= cached?['avatar_url'] as String?;
      unawaited(_refreshPeerAvatar(peer));
    }
    if (!mounted || snapshot.phase != CallPhase.ended) {
      _closing = false;
      if (mounted) setState(() {});
      return;
    }
    if (_closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _calls.state.value.phase == CallPhase.ended &&
          Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      } else {
        _closing = false;
      }
    });
  }

  @override
  void dispose() {
    _calls.state.removeListener(_onStateChanged);
    _localRenderer?.srcObject = null;
    _remoteRenderer?.srcObject = null;
    unawaited(_localRenderer?.dispose());
    unawaited(_remoteRenderer?.dispose());
    super.dispose();
  }

  Future<void> _hangUp() async {
    await _calls.end();
  }

  Future<void> _enableVideo() async {
    try {
      await _calls.enableVideo();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось включить видео: $error')),
      );
    }
  }

  void _minimizeCall() {
    _calls.minimize();
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  Future<void> _toggleScreenShare() async {
    if (_calls.state.value.screenSharing) {
      await _calls.stopScreenShare();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Показать экран?'),
        content: const Text(
          'Собеседник увидит весь экран, включая уведомления и открытые приложения. '
          'После подтверждения система покажет запрос на запись экрана.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Продолжить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _calls.startScreenShare();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось показать экран: $error')),
      );
    }
  }

  String _status(CallSnapshot snapshot) {
    if (snapshot.detail != null && snapshot.detail!.isNotEmpty) {
      return snapshot.detail!;
    }
    return switch (snapshot.phase) {
      CallPhase.outgoing => 'Вызов…',
      CallPhase.incoming => 'Входящий вызов',
      CallPhase.connecting => 'Соединение…',
      CallPhase.connected => _formatDuration(snapshot.duration),
      CallPhase.ended => 'Звонок завершён',
      CallPhase.failed => snapshot.error ?? 'Ошибка соединения',
      CallPhase.idle => 'Готово',
    };
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      particleCount: 46,
      callWidgetPlacement: CallWidgetPlacement.top,
      callWidgetStyle: CallWidgetStyle.compact,
      openCallScreenAfterAnswer: false,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: ValueListenableBuilder<CallSnapshot>(
          valueListenable: _calls.state,
          builder: (context, snapshot, _) {
            _attachStreams(snapshot);
            return PopScope<void>(
              canPop:
                  _allowPop ||
                  snapshot.phase == CallPhase.ended ||
                  snapshot.phase == CallPhase.failed,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) _minimizeCall();
              },
              child: SafeArea(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (snapshot.video)
                      _videoBody(snapshot)
                    else
                      _audioBody(snapshot),
                    _topBar(snapshot),
                    if (snapshot.verificationEmojis.isNotEmpty)
                      Positioned(
                        left: 18,
                        right: snapshot.video ? 142 : 18,
                        top: 112,
                        child: _verificationCard(
                          snapshot.verificationEmojis,
                          compact: snapshot.video,
                        ),
                      ),
                    _controls(snapshot),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _videoBody(CallSnapshot snapshot) {
    final remote = _remoteRenderer;
    final local = _localRenderer;
    final mainRenderer = snapshot.screenSharing ? local : remote;
    final mainStream = snapshot.screenSharing
        ? snapshot.screenStream
        : snapshot.remoteStream;
    final previewRenderer = snapshot.screenSharing ? remote : local;
    final previewStream = snapshot.screenSharing
        ? snapshot.remoteStream
        : snapshot.localStream;
    final mainHasVideo = mainStream?.getVideoTracks().isNotEmpty == true;
    final previewHasVideo = previewStream?.getVideoTracks().isNotEmpty == true;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (mainRenderer != null && mainHasVideo)
          RTCVideoView(
            mainRenderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          )
        else
          _avatarPlaceholder(),
        if (previewRenderer != null && previewHasVideo)
          Positioned(
            right: 16,
            top: 72,
            width: 112,
            height: 164,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: GE.shadow.withValues(alpha: .55),
                  border: Border.all(color: GE.overlayWeak),
                ),
                child: RTCVideoView(
                  previewRenderer,
                  mirror: !snapshot.screenSharing,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _audioBody(CallSnapshot snapshot) {
    return _avatarPlaceholder();
  }

  Widget _avatarPlaceholder() {
    final displayName = _currentDisplayName;
    final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GhostAvatar(avatarUrl: _avatarUrl, fallbackText: initial, size: 108),
          const SizedBox(height: 18),
          Text(
            displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: GE.text,
              fontWeight: FontWeight.w800,
              fontSize: 24,
            ),
          ),
          const SizedBox(height: 6),
          Text('@$_currentPeer', style: TextStyle(color: GE.sub, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _topBar(CallSnapshot snapshot) {
    return Positioned(
      left: 12,
      right: 12,
      top: 8,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(CupertinoIcons.chevron_down, color: GE.text),
            tooltip: 'Свернуть звонок',
            onPressed: _minimizeCall,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _currentDisplayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GE.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '${snapshot.video ? 'Видеозвонок' : 'Аудиозвонок'} · ${_status(snapshot)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: GE.text.withValues(alpha: .7)),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 88,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (snapshot.connectionState != 'new')
                  Text(
                    _connectionLabel(snapshot.connectionState),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: GE.text.withValues(alpha: .55),
                      fontSize: 11,
                    ),
                  ),
                if (snapshot.mediaRoute != CallMediaRoute.unknown)
                  Text(
                    '${snapshot.mediaRoute == CallMediaRoute.turnRelay ? 'TURN' : 'P2P'}'
                    '${snapshot.latencyMs == null ? '' : ' · ${snapshot.latencyMs} мс'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: GE.text.withValues(alpha: .55),
                      fontSize: 11,
                    ),
                  ),
                if (snapshot.latencyMs != null)
                  Text(
                    'Качество: ${_qualityLabel(snapshot.latencyMs!)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: GE.text.withValues(alpha: .55),
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _qualityLabel(int latencyMs) {
    if (latencyMs <= 150) return 'хорошее';
    if (latencyMs <= 300) return 'среднее';
    return 'слабое';
  }

  String _connectionLabel(String state) => switch (state.toLowerCase()) {
    'connecting' => 'Подключение',
    'connected' => 'На связи',
    'disconnected' => 'Восстанавливаем связь',
    'failed' => 'Связь потеряна',
    'closed' => 'Звонок завершён',
    _ => state,
  };

  Widget _verificationCard(List<String> emojis, {bool compact = false}) {
    return GlassCard(
      lite: true,
      padding: compact
          ? const EdgeInsets.fromLTRB(12, 10, 12, 11)
          : const EdgeInsets.fromLTRB(14, 11, 14, 13),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.checkmark_shield,
                color: GE.primary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: compact
                    ? Text(
                        'Сверь код',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: GE.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Проверка звонка',
                            style: TextStyle(
                              color: GE.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Сверь эти эмодзи с собеседником',
                            style: TextStyle(color: GE.sub, fontSize: 11),
                          ),
                        ],
                      ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: EmojiText(
              emojis.join('  '),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: compact ? 26 : 30, height: 1.0),
              allowFormatting: false,
              scale: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls(CallSnapshot snapshot) {
    final hasLocalCamera =
        snapshot.localStream?.getVideoTracks().isNotEmpty == true;
    return Positioned(
      left: 16,
      right: 16,
      bottom: 18,
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Wrap(
          alignment: WrapAlignment.spaceEvenly,
          spacing: 12,
          runSpacing: 10,
          children: [
            _CallButton(
              icon: snapshot.muted
                  ? CupertinoIcons.mic_slash_fill
                  : CupertinoIcons.mic_fill,
              label: snapshot.muted ? 'Включить' : 'Микрофон',
              active: snapshot.muted,
              onTap: _calls.toggleMuted,
            ),
            _CallButton(
              icon: snapshot.speaker
                  ? CupertinoIcons.speaker_3_fill
                  : CupertinoIcons.speaker_1,
              label: snapshot.speaker ? 'Динамик' : 'Телефон',
              active: snapshot.speaker,
              onTap: _calls.toggleSpeaker,
            ),
            if (snapshot.phase == CallPhase.connected &&
                !hasLocalCamera &&
                !snapshot.screenSharing)
              _CallButton(
                icon: CupertinoIcons.videocam_fill,
                label: 'Включить видео',
                onTap: _enableVideo,
              ),
            if (hasLocalCamera && !snapshot.screenSharing)
              _CallButton(
                icon: snapshot.cameraEnabled
                    ? CupertinoIcons.videocam_fill
                    : CupertinoIcons.videocam,
                label: snapshot.cameraEnabled ? 'Камера' : 'Выкл.',
                active: !snapshot.cameraEnabled,
                onTap: _calls.toggleCamera,
              ),
            if (hasLocalCamera && !snapshot.screenSharing)
              _CallButton(
                icon: CupertinoIcons.camera_rotate,
                label: 'Сменить',
                onTap: _calls.switchCamera,
              ),
            if (snapshot.phase == CallPhase.connected)
              _CallButton(
                icon: snapshot.screenSharing
                    ? Icons.stop_screen_share
                    : Icons.screen_share,
                label: snapshot.screenSharing ? 'Стоп экрана' : 'Экран',
                active: snapshot.screenSharing,
                onTap: _toggleScreenShare,
              ),
            _CallButton(
              icon: CupertinoIcons.phone_down_fill,
              label: 'Завершить',
              danger: true,
              onTap: _hangUp,
            ),
          ],
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  const _CallButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final bool active;
  final bool danger;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final color = danger
        ? GE.red
        : active
        ? GE.primary
        : GE.text;
    return GestureDetector(
      onTap: () => unawaited(onTap()),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .16),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(height: 6),
          Text(label, style: TextStyle(color: GE.sub, fontSize: 10)),
        ],
      ),
    );
  }
}
