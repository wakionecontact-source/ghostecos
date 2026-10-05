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
  String? _avatarUrl;

  @override
  void initState() {
    super.initState();
    _avatarUrl = ChatRepo.instance.getPeerAvatarCached(widget.peer);
    final cached = ProfileCache.instance.getProfileSync(widget.peer);
    _avatarUrl ??= cached?['avatar_url'] as String?;
    _calls.state.addListener(_onStateChanged);
    unawaited(_refreshPeerAvatar());
    unawaited(_initRenderers());
  }

  Future<void> _refreshPeerAvatar() async {
    try {
      final profile = await ApiClient().socGet(
        '/prof/${Uri.encodeComponent(widget.peer)}',
      );
      if (profile is! Map) return;
      final remote = profile['avatar_url']?.toString().trim();
      if (remote == null || remote.isEmpty) return;
      // Do not rebuild or rewrite the cache when the server still has the
      // same avatar that was already rendered from memory.
      if (remote != _avatarUrl && mounted) {
        setState(() => _avatarUrl = remote);
      }
      if (remote != ChatRepo.instance.getPeerAvatarCached(widget.peer)) {
        await ChatRepo.instance.cachePeerAvatar(widget.peer, remote);
      }
      final cachedProfile = ProfileCache.instance.getProfileSync(widget.peer);
      if (cachedProfile == null || cachedProfile['avatar_url'] != remote) {
        await ProfileCache.instance.setProfile(
          widget.peer,
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
    _localRenderer?.srcObject = snapshot.localStream;
    _remoteRenderer?.srcObject = snapshot.remoteStream;
  }

  void _onStateChanged() {
    final snapshot = _calls.state.value;
    _attachStreams(snapshot);
    if (!mounted || snapshot.phase != CallPhase.ended) {
      if (mounted) setState(() {});
      return;
    }
    if (_closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
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
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: ValueListenableBuilder<CallSnapshot>(
          valueListenable: _calls.state,
          builder: (context, snapshot, _) {
            _attachStreams(snapshot);
            return SafeArea(
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
                      right: 18,
                      top: 112,
                      child: _verificationCard(snapshot.verificationEmojis),
                    ),
                  _controls(snapshot),
                ],
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
    return Stack(
      fit: StackFit.expand,
      children: [
        if (remote != null && snapshot.remoteStream != null)
          RTCVideoView(
            remote,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          )
        else
          _avatarPlaceholder(),
        if (local != null && snapshot.localStream != null)
          Positioned(
            right: 16,
            top: 72,
            width: 112,
            height: 164,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .55),
                  border: Border.all(color: Colors.white24),
                ),
                child: RTCVideoView(
                  local,
                  mirror: true,
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
    final initial = widget.displayName.isNotEmpty
        ? widget.displayName[0].toUpperCase()
        : '?';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GhostAvatar(avatarUrl: _avatarUrl, fallbackText: initial, size: 108),
          const SizedBox(height: 18),
          Text(
            widget.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: GE.text,
              fontWeight: FontWeight.w800,
              fontSize: 24,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '@${widget.peer}',
            style: TextStyle(color: GE.sub, fontSize: 13),
          ),
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
            icon: const Icon(CupertinoIcons.chevron_down, color: Colors.white),
            onPressed: _hangUp,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  snapshot.video ? 'Видеозвонок' : 'Аудиозвонок',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  _status(snapshot),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withValues(alpha: .7)),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (snapshot.connectionState != 'new')
                Text(
                  snapshot.connectionState,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .55),
                    fontSize: 11,
                  ),
                ),
              if (snapshot.mediaRoute != CallMediaRoute.unknown)
                Text(
                  snapshot.mediaRoute == CallMediaRoute.turnRelay
                      ? 'TURN'
                      : 'P2P',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .55),
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _verificationCard(List<String> emojis) {
    return GlassCard(
      lite: true,
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 13),
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
                child: Column(
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
              style: const TextStyle(fontSize: 30, height: 1.0),
              allowFormatting: false,
              scale: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls(CallSnapshot snapshot) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 18,
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
            if (snapshot.video)
              _CallButton(
                icon: snapshot.cameraEnabled
                    ? CupertinoIcons.videocam_fill
                    : CupertinoIcons.videocam,
                label: snapshot.cameraEnabled ? 'Камера' : 'Выкл.',
                active: !snapshot.cameraEnabled,
                onTap: _calls.toggleCamera,
              ),
            if (snapshot.video)
              _CallButton(
                icon: CupertinoIcons.camera_rotate,
                label: 'Сменить',
                onTap: _calls.switchCamera,
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
