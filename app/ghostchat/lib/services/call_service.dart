import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/local/app_logger.dart';
import '../models/call_media_route.dart';
import 'auth_service.dart';
import 'call_audio_constraints.dart';
import 'call_collision_policy.dart';
import 'call_verification_code.dart';
import 'ghost_sound_effects.dart';
import 'incoming_call_notification_service.dart';
import 'ws_client.dart';

enum CallPhase {
  idle,
  outgoing,
  incoming,
  connecting,
  connected,
  ended,
  failed,
}

class CallInvite {
  const CallInvite({
    required this.callId,
    required this.peer,
    required this.video,
    required this.sdp,
  });

  final String callId;
  final String peer;
  final bool video;
  final String sdp;
}

class CallSnapshot {
  const CallSnapshot({
    this.phase = CallPhase.idle,
    this.peer,
    this.callId,
    this.video = false,
    this.screenSharing = false,
    this.minimized = false,
    this.muted = false,
    this.speaker = false,
    this.cameraEnabled = true,
    this.localStream,
    this.screenStream,
    this.remoteStream,
    this.duration = Duration.zero,
    this.connectionState = 'new',
    this.error,
    this.detail,
    this.mediaRoute = CallMediaRoute.unknown,
    this.latencyMs,
    this.verificationEmojis = const [],
  });

  final CallPhase phase;
  final String? peer;
  final String? callId;
  final bool video;
  final bool screenSharing;
  final bool minimized;
  final bool muted;
  final bool speaker;
  final bool cameraEnabled;
  final MediaStream? localStream;
  final MediaStream? screenStream;
  final MediaStream? remoteStream;
  final Duration duration;
  final String connectionState;
  final String? error;
  final String? detail;
  final CallMediaRoute mediaRoute;
  final int? latencyMs;
  final List<String> verificationEmojis;

  CallSnapshot copyWith({
    CallPhase? phase,
    String? peer,
    String? callId,
    bool? video,
    bool? screenSharing,
    bool? minimized,
    bool? muted,
    bool? speaker,
    bool? cameraEnabled,
    MediaStream? localStream,
    MediaStream? screenStream,
    MediaStream? remoteStream,
    Duration? duration,
    String? connectionState,
    String? error,
    String? detail,
    CallMediaRoute? mediaRoute,
    int? latencyMs,
    List<String>? verificationEmojis,
    bool clearDetail = false,
    bool clearScreenStream = false,
  }) {
    return CallSnapshot(
      phase: phase ?? this.phase,
      peer: peer ?? this.peer,
      callId: callId ?? this.callId,
      video: video ?? this.video,
      screenSharing: screenSharing ?? this.screenSharing,
      minimized: minimized ?? this.minimized,
      muted: muted ?? this.muted,
      speaker: speaker ?? this.speaker,
      cameraEnabled: cameraEnabled ?? this.cameraEnabled,
      localStream: localStream ?? this.localStream,
      screenStream: clearScreenStream
          ? null
          : screenStream ?? this.screenStream,
      remoteStream: remoteStream ?? this.remoteStream,
      duration: duration ?? this.duration,
      connectionState: connectionState ?? this.connectionState,
      error: error ?? this.error,
      detail: clearDetail ? null : detail ?? this.detail,
      mediaRoute: mediaRoute ?? this.mediaRoute,
      latencyMs: latencyMs ?? this.latencyMs,
      verificationEmojis: verificationEmojis ?? this.verificationEmojis,
    );
  }
}

/// WebRTC calls with relay-only signaling.
///
/// Media is peer-to-peer whenever ICE can establish a direct path. The server
/// may provide TURN credentials through `call.ice`; the built-in STUN list is
/// kept as a development fallback.
class CallService {
  CallService._();

  static final CallService instance = CallService._();
  static const MethodChannel _callAudioChannel = MethodChannel(
    'ghostchat/call_audio',
  );

  static const _defaultIceServers = <Map<String, dynamic>>[
    {
      'urls': ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'],
    },
  ];

  final ValueNotifier<CallSnapshot> state = ValueNotifier<CallSnapshot>(
    const CallSnapshot(),
  );
  final ValueNotifier<CallInvite?> incoming = ValueNotifier<CallInvite?>(null);

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  MediaStream? _extraVideoStream;
  MediaStream? _screenStream;
  RTCRtpSender? _videoSender;
  RTCRtpTransceiver? _videoTransceiver;
  bool _cameraEnabledBeforeShare = true;
  bool _screenShareOwnsVideoTransceiver = false;
  bool _screenShareStopping = false;
  bool _screenCaptureBackgroundEnabled = false;
  String? _peer;
  String? _callId;
  bool _remoteDescriptionReady = false;
  bool _initialized = false;
  Future<void>? _initializing;
  bool _currentVideo = false;
  bool _muted = false;
  bool _speaker = false;
  bool _cameraEnabled = true;
  DateTime? _connectedAt;
  bool _remoteVideoSending = false;
  List<Map<String, dynamic>> _iceServers = _defaultIceServers;
  String? _localUsername;
  bool _localDescriptionSignaled = false;
  int _iceGeneration = 0;
  bool _hasTurnServers = false;
  final bool _relayOnly = false;
  bool _iceRecoveryActive = false;
  bool _iceRestartInFlight = false;
  int _iceRestartAttempts = 0;
  Timer? _relayFallbackTimer;
  Timer? _iceRestartTimer;
  Timer? _iceRestartResponseTimer;
  Timer? _mediaRouteTimer;
  Completer<void>? _mediaNegotiationCompleter;
  String? _routeStatsCallIdInFlight;
  CallMediaRoute _mediaRoute = CallMediaRoute.unknown;
  String? _verificationLocalSdp;
  String? _verificationRemoteSdp;
  int _verificationRevision = 0;
  final List<Map<String, dynamic>> _localIceQueue = [];

  final Map<String, List<RTCIceCandidate>> _pendingCandidates = {};
  Timer? _ringTimer;
  Timer? _ringSoundTimer;
  Timer? _connectTimer;
  Timer? _disconnectTimer;
  Timer? _durationTimer;
  bool _ending = false;

  bool get isActive => switch (state.value.phase) {
    CallPhase.outgoing ||
    CallPhase.incoming ||
    CallPhase.connecting ||
    CallPhase.connected => true,
    _ => false,
  };

  bool _ownsActiveCall(String callId) =>
      _callId == callId && state.value.callId == callId && isActive;

  bool get _isIceRestartLeader {
    final local = (_localUsername ?? '').toLowerCase();
    final remote = (_peer ?? '').toLowerCase();
    return local.isNotEmpty && remote.isNotEmpty && local.compareTo(remote) < 0;
  }

  Future<void> initialize() async {
    final running = _initializing;
    if (running != null) {
      await running;
      return;
    }
    if (_initialized) return;
    _initialized = true;
    final future = () async {
      _localUsername = await AuthService.username();
      WsClient.instance.on('call.signal', _onSignal);
      WsClient.instance.on('call.signal.err', (dynamic payload) {
        final data = _asMap(payload);
        final message = data['error']?.toString() ?? 'Сигнал звонка отклонён';
        appLog.warn('call', 'call.signal.err: $message');
        if (isActive) unawaited(_fail(message));
      });
    }();
    _initializing = future;
    try {
      await future;
    } finally {
      if (identical(_initializing, future)) _initializing = null;
    }
  }

  Future<void> startOutgoing({required String peer, bool video = false}) async {
    await initialize();
    if (isActive) throw StateError('Звонок уже выполняется');

    final normalizedPeer = _normalizePeer(peer);
    if (normalizedPeer.isEmpty) throw ArgumentError('Не указан собеседник');

    await WsClient.instance.connect();
    if (!WsClient.instance.isConnected) {
      throw StateError('Нет соединения с сервером сигнализации');
    }

    _peer = normalizedPeer;
    _callId = _newCallId();
    _resetNegotiationState();
    _currentVideo = video;
    _remoteVideoSending = video;
    _muted = false;
    _speaker = false;
    _cameraEnabled = true;
    _videoSender = null;
    _videoTransceiver = null;
    _extraVideoStream = null;
    _screenStream = null;
    _screenShareStopping = false;
    _screenShareOwnsVideoTransceiver = false;
    _setState(
      CallSnapshot(
        phase: CallPhase.outgoing,
        peer: _peer,
        callId: _callId,
        video: video,
      ),
    );
    // Start immediately, so the caller hears the outgoing tone while media
    // permissions/ICE are still being prepared, not only after the offer.
    _startRingSound();

    try {
      _iceServers = await _loadIceServers();
      await _createPeerConnection();
      _localStream = await _openMedia(video);
      await _setLocalTracks();

      final offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': video,
      });
      await _peerConnection!.setLocalDescription(offer);
      await _updateVerificationSdp(localSdp: offer.sdp);
      _sendSignal({
        'kind': 'offer',
        'sdp': offer.sdp,
        'video': video,
        'ice_generation': _iceGeneration,
      });
      _localDescriptionSignaled = true;
      _flushLocalIce();
      _setState(state.value.copyWith(phase: CallPhase.connecting));
      _armRingTimeout();
      _armConnectTimeout();
    } catch (error, stackTrace) {
      appLog.error('call', 'Outgoing call setup failed: $error\n$stackTrace');
      await _fail(_friendlyError(error));
      rethrow;
    }
  }

  Future<void> acceptIncoming() async {
    final invite = incoming.value;
    if (invite == null ||
        (isActive && state.value.phase != CallPhase.incoming)) {
      return;
    }

    incoming.value = null;
    unawaited(IncomingCallNotificationService.instance.clearIncomingCall());
    _cancelRingTimer();
    _peer = invite.peer;
    _callId = invite.callId;
    _resetNegotiationState(clearCandidates: false);
    _currentVideo = invite.video;
    _remoteVideoSending = invite.video;
    _muted = false;
    _speaker = false;
    _cameraEnabled = true;
    _videoSender = null;
    _videoTransceiver = null;
    _extraVideoStream = null;
    _screenStream = null;
    _screenShareStopping = false;
    _screenShareOwnsVideoTransceiver = false;
    _setState(
      CallSnapshot(
        phase: CallPhase.connecting,
        peer: _peer,
        callId: _callId,
        video: invite.video,
      ),
    );

    try {
      _iceServers = await _loadIceServers();
      await _createPeerConnection();
      _localStream = await _openMedia(invite.video);
      await _setLocalTracks();
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(invite.sdp, 'offer'),
      );
      await _updateVerificationSdp(remoteSdp: invite.sdp);
      _remoteDescriptionReady = true;
      await _flushCandidates(invite.callId);

      final answer = await _peerConnection!.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': invite.video,
      });
      await _peerConnection!.setLocalDescription(answer);
      await _updateVerificationSdp(localSdp: answer.sdp);
      _sendSignal({
        'kind': 'answer',
        'sdp': answer.sdp,
        'video': invite.video,
        'ice_generation': _iceGeneration,
      });
      _localDescriptionSignaled = true;
      _flushLocalIce();
      _armConnectTimeout();
    } catch (error, stackTrace) {
      appLog.error('call', 'Incoming call setup failed: $error\n$stackTrace');
      await _fail(_friendlyError(error));
    }
  }

  Future<void> rejectIncoming() async {
    final invite = incoming.value;
    if (invite == null) return;
    incoming.value = null;
    unawaited(IncomingCallNotificationService.instance.clearIncomingCall());
    _cancelRingTimer();
    _peer = invite.peer;
    _callId = invite.callId;
    await end(notify: true, signalKind: 'reject');
  }

  Future<void> toggleMuted() async {
    _muted = !_muted;
    for (final track
        in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !_muted;
    }
    _setState(state.value.copyWith(muted: _muted));
  }

  Future<void> toggleSpeaker() async {
    if (Platform.isWindows) return;
    _speaker = !_speaker;
    await Helper.setSpeakerphoneOn(_speaker);
    _setState(state.value.copyWith(speaker: _speaker));
  }

  Future<void> toggleCamera() async {
    if (!_currentVideo || state.value.screenSharing) return;
    _cameraEnabled = !_cameraEnabled;
    for (final track
        in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = _cameraEnabled;
    }
    _setState(state.value.copyWith(cameraEnabled: _cameraEnabled));
  }

  Future<void> switchCamera() async {
    if (!_currentVideo || state.value.screenSharing) return;
    final track = _localStream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    await Helper.switchCamera(track);
  }

  void minimize() {
    if (isActive) _setState(state.value.copyWith(minimized: true));
  }

  void restore() {
    if (isActive) _setState(state.value.copyWith(minimized: false));
  }

  Future<void> enableVideo() async {
    if (state.value.phase != CallPhase.connected ||
        _localStream?.getVideoTracks().isNotEmpty == true) {
      return;
    }
    final peerConnection = _peerConnection;
    final local = _localStream;
    if (peerConnection == null || local == null) {
      throw StateError('Звонок ещё не подключён');
    }

    final cameraPermission = await Permission.camera.request();
    if (!cameraPermission.isGranted) {
      throw StateError('Нет доступа к камере');
    }
    final cameraStream = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        'facingMode': 'user',
        'width': {'ideal': 1280, 'max': 1920},
        'height': {'ideal': 720, 'max': 1080},
        'frameRate': {'ideal': 24, 'max': 30},
      },
    });
    final cameraTrack = cameraStream.getVideoTracks().firstOrNull;
    if (cameraTrack == null) {
      await cameraStream.dispose();
      throw StateError('Камера не создала видеопоток');
    }

    try {
      await local.addTrack(cameraTrack, addToNative: true);
      final transceiver = _videoTransceiver ?? await _findVideoTransceiver();
      if (transceiver != null) {
        _videoTransceiver = transceiver;
        await transceiver.setDirection(TransceiverDirection.SendRecv);
        await transceiver.sender.replaceTrack(cameraTrack);
        _videoSender = transceiver.sender;
      } else {
        _videoSender = await peerConnection.addTrack(cameraTrack, local);
      }
      _extraVideoStream = cameraStream;
      _currentVideo = true;
      _cameraEnabled = true;
      _setState(
        state.value.copyWith(
          video: true,
          cameraEnabled: true,
          localStream: local,
          clearDetail: true,
        ),
      );
      await _negotiateMediaChange();
    } catch (_) {
      if (!identical(_extraVideoStream, cameraStream)) {
        for (final track in cameraStream.getTracks()) {
          track.stop();
        }
        await cameraStream.dispose();
      }
      rethrow;
    }
  }

  Future<void> startScreenShare() async {
    if (state.value.phase != CallPhase.connected) {
      throw StateError('Сначала дождитесь соединения');
    }
    if (state.value.screenSharing) return;
    final peerConnection = _peerConnection;
    final local = _localStream;
    if (peerConnection == null || local == null) {
      throw StateError('Звонок уже завершён');
    }

    final cameraTrack = local.getVideoTracks().firstOrNull;
    final existingSender = _videoSender ?? await _findVideoSender();
    var streamAdded = false;
    var cameraWasReplaced = false;
    MediaStream? stream;
    MediaStreamTrack? screenTrack;
    RTCRtpSender? sender = existingSender;
    try {
      await _startScreenCaptureBackground();
      stream = await navigator.mediaDevices.getDisplayMedia({
        'audio': false,
        'video': {
          'frameRate': {'ideal': 15, 'max': 24},
        },
      });
      screenTrack = stream.getVideoTracks().firstOrNull;
      if (screenTrack == null) {
        throw StateError('Система не вернула изображение экрана');
      }

      if (cameraTrack != null && sender != null) {
        _cameraEnabledBeforeShare = _cameraEnabled;
        await sender.replaceTrack(screenTrack);
        cameraWasReplaced = true;
        cameraTrack.enabled = false;
      } else {
        final transceiver =
            _videoTransceiver ??
            await _findVideoTransceiver() ??
            await peerConnection.addTransceiver(
              kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
              init: RTCRtpTransceiverInit(
                direction: TransceiverDirection.SendRecv,
                streams: [local],
              ),
            );
        _videoTransceiver = transceiver;
        _screenShareOwnsVideoTransceiver = true;
        streamAdded = true;
        await transceiver.setDirection(TransceiverDirection.SendRecv);
        sender = transceiver.sender;
        await sender.replaceTrack(screenTrack);
      }

      _videoSender = sender;
      _currentVideo = true;
      _cameraEnabled = false;
      _screenStream = stream;
      screenTrack.onEnded = () => unawaited(stopScreenShare());
      _setState(
        state.value.copyWith(
          video: true,
          screenSharing: true,
          cameraEnabled: false,
          screenStream: stream,
          clearDetail: true,
        ),
      );
      if (streamAdded) await _negotiateMediaChange();
    } catch (_) {
      if (cameraWasReplaced && sender != null) {
        try {
          await sender.replaceTrack(cameraTrack);
          if (cameraTrack != null) {
            cameraTrack.enabled = _cameraEnabledBeforeShare;
          }
          _cameraEnabled = _cameraEnabledBeforeShare;
        } catch (_) {}
      }
      if (streamAdded) {
        try {
          await sender?.replaceTrack(null);
          await _videoTransceiver?.setDirection(TransceiverDirection.RecvOnly);
        } catch (_) {}
        _screenShareOwnsVideoTransceiver = false;
        _currentVideo = _remoteVideoSending;
        _cameraEnabled = true;
      }
      if (screenTrack != null) {
        screenTrack.onEnded = null;
      }
      for (final track in stream?.getTracks() ?? <MediaStreamTrack>[]) {
        track.stop();
      }
      await stream?.dispose();
      _screenStream = null;
      _setState(
        state.value.copyWith(
          video: _currentVideo,
          screenSharing: false,
          cameraEnabled: _cameraEnabled,
          clearScreenStream: true,
        ),
      );
      await _stopScreenCaptureBackground();
      rethrow;
    }
  }

  Future<void> stopScreenShare() async {
    if (_screenShareStopping || _screenStream == null) return;
    _screenShareStopping = true;
    final activeNegotiation = _mediaNegotiationCompleter;
    if (activeNegotiation != null && !activeNegotiation.isCompleted) {
      try {
        await activeNegotiation.future.timeout(const Duration(seconds: 16));
      } catch (_) {}
    }

    final stream = _screenStream;
    final screenTrack = stream?.getVideoTracks().firstOrNull;
    if (screenTrack != null) screenTrack.onEnded = null;
    try {
      final cameraTrack = _localStream?.getVideoTracks().firstOrNull;
      final sender = _videoSender ?? await _findVideoSender();
      if (_screenShareOwnsVideoTransceiver) {
        if (sender != null) await sender.replaceTrack(null);
        await _videoTransceiver?.setDirection(TransceiverDirection.RecvOnly);
        _currentVideo = _remoteVideoSending;
        _cameraEnabled = true;
        if (state.value.phase == CallPhase.connected) {
          await _negotiateMediaChange();
        }
      } else {
        if (sender != null) await sender.replaceTrack(cameraTrack);
        if (cameraTrack != null) {
          cameraTrack.enabled = _cameraEnabledBeforeShare;
        }
        _cameraEnabled = _cameraEnabledBeforeShare;
      }
    } catch (error) {
      appLog.warn(
        'call',
        'Could not restore call video after screen share: $error',
      );
      if (_screenShareOwnsVideoTransceiver) {
        _currentVideo = _remoteVideoSending;
        _cameraEnabled = true;
      } else {
        _currentVideo = true;
        _cameraEnabled = _cameraEnabledBeforeShare;
      }
    } finally {
      screenTrack?.stop();
      await stream?.dispose();
      _screenStream = null;
      _screenShareOwnsVideoTransceiver = false;
      _setState(
        state.value.copyWith(
          video: _currentVideo,
          screenSharing: false,
          cameraEnabled: _cameraEnabled,
          clearScreenStream: true,
        ),
      );
      _screenShareStopping = false;
      await _stopScreenCaptureBackground();
    }
  }

  Future<RTCRtpSender?> _findVideoSender() async {
    final pc = _peerConnection;
    if (pc == null) return null;
    final senders = await pc.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind == 'video') return sender;
    }
    return null;
  }

  Future<RTCRtpTransceiver?> _findVideoTransceiver() async {
    final pc = _peerConnection;
    if (pc == null) return null;
    for (final transceiver in await pc.getTransceivers()) {
      if (transceiver.sender.track?.kind == 'video' ||
          transceiver.receiver.track?.kind == 'video') {
        return transceiver;
      }
    }
    return null;
  }

  bool _sdpSendsVideo(String sdp) {
    var inVideoSection = false;
    var sessionDirection = 'sendrecv';
    var direction = 'sendrecv';
    bool sendsVideo() => direction == 'sendrecv' || direction == 'sendonly';

    for (final rawLine in sdp.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim().toLowerCase();
      if (line.startsWith('m=')) {
        if (inVideoSection && sendsVideo()) return true;
        inVideoSection = line.startsWith('m=video ');
        direction = sessionDirection;
      } else if (inVideoSection && line.startsWith('a=')) {
        final attribute = line.substring(2);
        if (attribute == 'sendrecv' ||
            attribute == 'sendonly' ||
            attribute == 'recvonly' ||
            attribute == 'inactive') {
          if (inVideoSection) {
            direction = attribute;
          } else {
            sessionDirection = attribute;
          }
        }
      }
    }
    return inVideoSection && sendsVideo();
  }

  Future<void> _negotiateMediaChange() async {
    final pc = _peerConnection;
    final callId = _callId;
    if (pc == null || callId == null) {
      throw StateError('Звонок завершён');
    }
    if (_mediaNegotiationCompleter != null) {
      throw StateError('Уже меняем параметры звонка');
    }
    final completer = Completer<void>();
    _mediaNegotiationCompleter = completer;
    try {
      _localDescriptionSignaled = false;
      final offer = await pc.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });
      await pc.setLocalDescription(offer);
      await _updateVerificationSdp(localSdp: offer.sdp);
      _sendSignal({
        'kind': 'media-offer',
        'sdp': offer.sdp,
        'ice_generation': _iceGeneration,
      });
      _localDescriptionSignaled = true;
      _flushLocalIce();
      await completer.future.timeout(const Duration(seconds: 15));
    } finally {
      if (identical(_mediaNegotiationCompleter, completer)) {
        _mediaNegotiationCompleter = null;
      }
    }
  }

  Future<void> _handleMediaOffer(
    String callId,
    String from,
    Map<String, dynamic> data,
  ) async {
    if (!_ownsActiveCall(callId) || from != _peer) return;
    final sdp = data['sdp']?.toString();
    final pc = _peerConnection;
    if (sdp == null || sdp.isEmpty || pc == null) return;
    try {
      _localDescriptionSignaled = false;
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      await _updateVerificationSdp(remoteSdp: sdp);
      _remoteDescriptionReady = true;
      _videoTransceiver ??= await _findVideoTransceiver();
      await _flushCandidates(callId);
      final answer = await pc.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });
      await pc.setLocalDescription(answer);
      await _updateVerificationSdp(localSdp: answer.sdp);
      _sendSignal({
        'kind': 'media-answer',
        'sdp': answer.sdp,
        'ice_generation': _iceGeneration,
      });
      _localDescriptionSignaled = true;
      _flushLocalIce();
      _remoteVideoSending = _sdpSendsVideo(sdp);
      _currentVideo =
          _remoteVideoSending ||
          (_localStream?.getVideoTracks().isNotEmpty == true);
      _setState(state.value.copyWith(video: _currentVideo, clearDetail: true));
    } catch (error) {
      appLog.warn('call', 'Media renegotiation failed: $error');
      _setState(state.value.copyWith(detail: 'Не удалось включить видео'));
    }
  }

  Future<void> _startScreenCaptureBackground() async {
    if (!Platform.isAndroid) return;
    final initialized = await FlutterBackground.initialize(
      androidConfig: const FlutterBackgroundAndroidConfig(
        notificationTitle: 'GhostChat',
        notificationText: 'Идёт демонстрация экрана в звонке',
        notificationImportance: AndroidNotificationImportance.normal,
        notificationIcon: AndroidResource(
          name: 'ic_notification',
          defType: 'drawable',
        ),
        enableWifiLock: false,
        shouldRequestBatteryOptimizationsOff: false,
      ),
    );
    if (!initialized) {
      throw StateError('Не удалось подготовить показ экрана');
    }
    if (!FlutterBackground.isBackgroundExecutionEnabled) {
      final enabled = await FlutterBackground.enableBackgroundExecution();
      if (!enabled) throw StateError('Не удалось запустить показ экрана');
    }
    _screenCaptureBackgroundEnabled = true;
  }

  Future<void> _stopScreenCaptureBackground() async {
    if (!Platform.isAndroid || !_screenCaptureBackgroundEnabled) return;
    _screenCaptureBackgroundEnabled = false;
    try {
      await FlutterBackground.disableBackgroundExecution();
    } catch (error) {
      appLog.warn('call', 'Screen-share service stop failed: $error');
    }
  }

  Future<void> end({
    bool notify = true,
    String signalKind = 'hangup',
    CallPhase finalPhase = CallPhase.ended,
    String? error,
  }) async {
    if (_ending) return;
    _ending = true;
    final peer = _peer;
    final callId = _callId;
    try {
      // Stop an already playing ring tone before any signaling or WebRTC
      // cleanup so an unavailable call does not leave audio behind.
      _stopRingSound();

      if (notify && peer != null && callId != null) {
        _sendSignal({'kind': signalKind});
      }

      // WebRTC can leave Android in speakerphone mode after the peer
      // connection is closed. Restore the normal route before releasing the
      // media session, and explicitly disable the microphone tracks first.
      final hadCallAudio = _localStream != null || _speaker;
      for (final track
          in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
        track.enabled = false;
      }
      if (hadCallAudio && !Platform.isWindows) {
        try {
          await Helper.setSpeakerphoneOn(false);
        } catch (routeError) {
          appLog.warn('call', 'Audio route reset failed: $routeError');
        }
      }

      _cancelTimers();
      final mediaNegotiation = _mediaNegotiationCompleter;
      _mediaNegotiationCompleter = null;
      if (mediaNegotiation != null && !mediaNegotiation.isCompleted) {
        mediaNegotiation.completeError(StateError('Звонок завершён'));
      }
      final connection = _peerConnection;
      _peerConnection = null;
      try {
        await connection?.close();
      } catch (closeError) {
        appLog.warn('call', 'Peer connection close failed: $closeError');
      }
      await _disposeMedia();
      await _resetCommunicationAudio();
      _pendingCandidates.remove(callId);
      _localIceQueue.clear();
      _remoteDescriptionReady = false;
      _localDescriptionSignaled = false;
      _iceRecoveryActive = false;
      _iceRestartInFlight = false;
      _iceRestartAttempts = 0;
      _iceGeneration = 0;
      _mediaRoute = CallMediaRoute.unknown;
      _verificationRevision++;
      _verificationLocalSdp = null;
      _verificationRemoteSdp = null;
      _peer = null;
      _callId = null;
      _connectedAt = null;
      _muted = false;
      _speaker = false;
      _cameraEnabled = true;
      _videoSender = null;
      _videoTransceiver = null;
      _extraVideoStream = null;
      _screenStream = null;
      _screenShareStopping = false;
      _screenShareOwnsVideoTransceiver = false;
      _currentVideo = false;
      _remoteVideoSending = false;
      incoming.value = null;
      unawaited(IncomingCallNotificationService.instance.clearIncomingCall());
      _setState(
        CallSnapshot(
          phase: finalPhase,
          error: error,
          mediaRoute: CallMediaRoute.unknown,
        ),
      );
    } finally {
      _ending = false;
    }
  }

  Future<void> dispose() async {
    await end(notify: false);
    state.dispose();
    incoming.dispose();
  }

  Future<void> _resetCommunicationAudio() async {
    if (!Platform.isAndroid) return;
    try {
      await _callAudioChannel.invokeMethod<void>('resetCommunicationAudio');
    } catch (error) {
      // The native reset is best effort. WebRTC still owns its normal cleanup
      // path, and this keeps calls usable on older/custom Android builds.
      appLog.warn('call', 'System audio mode reset failed: $error');
    }
  }

  Future<void> _createPeerConnection() async {
    _peerConnection = await createPeerConnection({
      'sdpSemantics': 'unified-plan',
      'iceServers': _iceServers,
      'bundlePolicy': 'max-bundle',
      'continualGatheringPolicy': 'gather_continually',
      if (_relayOnly && _hasTurnServers) 'iceTransportPolicy': 'relay',
    });

    _peerConnection!
      ..onIceCandidate = (candidate) {
        if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
        final message = <String, dynamic>{
          'kind': 'candidate',
          'candidate': candidate.candidate,
          'sdp_mid': candidate.sdpMid,
          'sdp_mline_index': candidate.sdpMLineIndex,
          'ice_generation': _iceGeneration,
        };
        if (_localDescriptionSignaled) {
          _sendSignal(message);
        } else {
          _localIceQueue.add(message);
        }
      }
      ..onTrack = (event) {
        if (event.streams.isEmpty) return;
        _remoteStream = event.streams.first;
        _setState(
          state.value.copyWith(
            remoteStream: _remoteStream,
            phase: CallPhase.connected,
          ),
        );
        _markConnected();
      }
      ..onConnectionState = (connectionState) {
        final value = connectionState.name;
        _setState(state.value.copyWith(connectionState: value));
        switch (connectionState) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            _markConnected();
            _iceRecoveryActive = false;
            _iceRestartInFlight = false;
            _iceRestartAttempts = 0;
            _relayFallbackTimer?.cancel();
            _iceRestartTimer?.cancel();
            _iceRestartTimer = null;
            _iceRestartResponseTimer?.cancel();
            _iceRestartResponseTimer = null;
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            _beginIceRecovery();
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            _beginIceRecovery();
          case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
            if (!_ending && isActive) {
              unawaited(_fail('Не удалось установить соединение'));
            }
          default:
            break;
        }
      };
    _peerConnection!.onIceConnectionState = (iceState) {
      if (iceState == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          iceState == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _beginIceRecovery();
      }
    };
  }

  Future<MediaStream> _openMedia(bool video) async {
    final microphone = await Permission.microphone.request();
    if (!microphone.isGranted) throw StateError('Нет доступа к микрофону');
    if (video) {
      final camera = await Permission.camera.request();
      if (!camera.isGranted) throw StateError('Нет доступа к камере');
    }

    return navigator.mediaDevices.getUserMedia({
      'audio': callAudioConstraints(),
      'video': video
          ? {
              'facingMode': 'user',
              'width': {'ideal': 1280, 'max': 1920},
              'height': {'ideal': 720, 'max': 1080},
              'frameRate': {'ideal': 24, 'max': 30},
            }
          : false,
    });
  }

  Future<void> _setLocalTracks() async {
    final connection = _peerConnection;
    final stream = _localStream;
    if (connection == null || stream == null) return;
    for (final track in stream.getTracks()) {
      final sender = await connection.addTrack(track, stream);
      if (track.kind == 'video') _videoSender = sender;
    }
    _setState(state.value.copyWith(localStream: stream));
  }

  Future<void> _onSignal(dynamic payload) async {
    final data = _asMap(payload);
    final from = _normalizePeer(
      (data['from'] ?? data['from_username'])?.toString() ?? '',
    );
    final callId = data['call_id']?.toString();
    final kind = data['kind']?.toString();
    if (from.isEmpty || callId == null || kind == null) return;

    if (kind == 'media-offer') {
      await _handleMediaOffer(callId, from, data);
      return;
    }

    if (kind == 'offer') {
      final sdp = data['sdp']?.toString();
      if (sdp == null || sdp.isEmpty) return;

      final existing = state.value;
      if (isActive) {
        final crossedCall =
            (existing.phase == CallPhase.outgoing ||
                existing.phase == CallPhase.connecting) &&
            _normalizePeer(existing.peer ?? '') == from;
        if (!crossedCall) {
          _sendSignalTo(from, {'kind': 'busy', 'call_id': callId});
          return;
        }
        final decision = resolveCallCollision(
          localUsername: _localUsername ??= await AuthService.username() ?? '',
          remoteUsername: from,
          localCallId: existing.callId ?? '',
          incomingCallId: callId,
        );
        if (decision == CallCollisionDecision.keepOutgoing) {
          _sendSignalTo(from, {'kind': 'busy', 'call_id': callId});
          return;
        }
        await end(notify: true, signalKind: 'hangup');
      }
      _peer = from;
      _callId = callId;
      _iceGeneration = _generationFrom(data);
      _remoteVideoSending = data['video'] == true;
      _currentVideo = _remoteVideoSending;
      incoming.value = CallInvite(
        callId: callId,
        peer: from,
        video: _currentVideo,
        sdp: sdp,
      );
      _setState(
        CallSnapshot(
          phase: CallPhase.incoming,
          peer: from,
          callId: callId,
          video: _currentVideo,
        ),
      );
      _sendSignalTo(from, {'kind': 'ringing', 'call_id': callId});
      _startRingSound();
      unawaited(
        IncomingCallNotificationService.instance.showIncomingCall(
          callId: callId,
          from: from,
          video: _currentVideo,
        ),
      );
      _armIncomingTimeout();
      return;
    }

    final pendingIncoming = incoming.value;
    if (kind == 'candidate' &&
        _peerConnection == null &&
        pendingIncoming?.callId == callId &&
        pendingIncoming?.peer == from) {
      _queueCandidate(callId, data);
      return;
    }

    if (callId != _callId || from != _peer) return;

    switch (kind) {
      case 'answer':
        final sdp = data['sdp']?.toString();
        if (sdp == null ||
            _peerConnection == null ||
            _generationFrom(data) != _iceGeneration) {
          return;
        }
        await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(sdp, 'answer'),
        );
        await _updateVerificationSdp(remoteSdp: sdp);
        _remoteDescriptionReady = true;
        await _flushCandidates(callId);
        _remoteVideoSending = data['video'] == true;
        _currentVideo =
            _remoteVideoSending ||
            (_localStream?.getVideoTracks().isNotEmpty == true);
        _setState(state.value.copyWith(video: _currentVideo));
      case 'media-answer':
        final sdp = data['sdp']?.toString();
        final pc = _peerConnection;
        if (sdp == null ||
            pc == null ||
            _generationFrom(data) != _iceGeneration) {
          return;
        }
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        await _updateVerificationSdp(remoteSdp: sdp);
        _remoteDescriptionReady = true;
        await _flushCandidates(callId);
        final mediaChange = _mediaNegotiationCompleter;
        if (mediaChange != null && !mediaChange.isCompleted) {
          mediaChange.complete();
        }
      case 'candidate':
        await _receiveCandidate(callId, data);
      case 'ice-restart-offer':
        await _handleIceRestartOffer(callId, from, data);
      case 'ice-restart-answer':
        await _handleIceRestartAnswer(callId, data);
      case 'hangup':
      case 'reject':
      case 'busy':
      case 'timeout':
        await end(notify: false);
    }
  }

  void _queueCandidate(String callId, Map<String, dynamic> data) {
    final candidate = _candidateFrom(data);
    if (candidate == null) return;
    _pendingCandidates
        .putIfAbsent(callId, () => <RTCIceCandidate>[])
        .add(candidate);
  }

  Future<void> _flushCandidates(String callId) async {
    final candidates = _pendingCandidates.remove(callId) ?? <RTCIceCandidate>[];
    for (final candidate in candidates) {
      await _peerConnection?.addCandidate(candidate);
    }
  }

  Future<void> _addCandidate(Map<String, dynamic> data) async {
    final candidate = _candidateFrom(data);
    if (candidate != null) await _peerConnection?.addCandidate(candidate);
  }

  Future<void> _receiveCandidate(
    String callId,
    Map<String, dynamic> data,
  ) async {
    if (_generationFrom(data) != _iceGeneration) return;
    if (_remoteDescriptionReady && _peerConnection != null) {
      await _addCandidate(data);
    } else {
      _queueCandidate(callId, data);
    }
  }

  Future<void> _handleIceRestartOffer(
    String callId,
    String from,
    Map<String, dynamic> data,
  ) async {
    if (!_ownsActiveCall(callId) ||
        from != _peer ||
        _isIceRestartLeader ||
        _generationFrom(data) <= _iceGeneration) {
      return;
    }
    final sdp = data['sdp']?.toString();
    final pc = _peerConnection;
    if (sdp == null || sdp.isEmpty || pc == null) return;
    _iceGeneration = _generationFrom(data);
    _setState(state.value.copyWith(detail: 'Переподключаем звонок…'));
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      await _updateVerificationSdp(remoteSdp: sdp);
      _remoteDescriptionReady = true;
      await _flushCandidates(callId);
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      await _updateVerificationSdp(localSdp: answer.sdp);
      _sendSignal({
        'kind': 'ice-restart-answer',
        'sdp': answer.sdp,
        'ice_generation': _iceGeneration,
      });
      _localDescriptionSignaled = true;
      _flushLocalIce();
    } catch (error) {
      appLog.warn('call', 'ICE restart answer failed: $error');
    }
  }

  Future<void> _handleIceRestartAnswer(
    String callId,
    Map<String, dynamic> data,
  ) async {
    if (!_ownsActiveCall(callId) ||
        !_isIceRestartLeader ||
        _generationFrom(data) != _iceGeneration) {
      return;
    }
    final sdp = data['sdp']?.toString();
    final pc = _peerConnection;
    if (sdp == null || sdp.isEmpty || pc == null) return;
    _iceRestartTimer?.cancel();
    _iceRestartTimer = null;
    _iceRestartResponseTimer?.cancel();
    _iceRestartResponseTimer = null;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      if (!_ownsActiveCall(callId)) return;
      await _updateVerificationSdp(remoteSdp: sdp);
      if (!_ownsActiveCall(callId)) return;
      _remoteDescriptionReady = true;
      await _flushCandidates(callId);
      if (!_ownsActiveCall(callId)) return;
      _iceRestartInFlight = false;
      _setState(state.value.copyWith(detail: 'Связь восстановлена'));
      _scheduleIceRestartRetry(
        callId: callId,
        delay: const Duration(seconds: 3),
      );
    } catch (error) {
      if (_callId != callId) return;
      _iceRestartInFlight = false;
      appLog.warn('call', 'ICE restart answer apply failed: $error');
      _scheduleIceRestartRetry(
        callId: callId,
        delay: const Duration(seconds: 1),
      );
    }
  }

  void _beginIceRecovery() {
    final callId = _callId;
    if (!isActive || _ending || callId == null) return;
    _iceRecoveryActive = true;
    if (_disconnectTimer?.isActive != true) {
      _disconnectTimer = Timer(const Duration(seconds: 30), () {
        if (_iceRecoveryActive && _ownsActiveCall(callId)) {
          unawaited(_fail('Соединение с собеседником потеряно'));
        }
      });
    }
    if (_isIceRestartLeader &&
        !_iceRestartInFlight &&
        _iceRestartTimer?.isActive != true) {
      final initialNegotiation = state.value.phase == CallPhase.connecting;
      final delay = initialNegotiation && _hasTurnServers
          ? const Duration(seconds: 7)
          : const Duration(seconds: 1);
      late final Timer restartTimer;
      restartTimer = Timer(delay, () {
        if (!identical(_iceRestartTimer, restartTimer) ||
            !_ownsActiveCall(callId)) {
          return;
        }
        _iceRestartTimer = null;
        unawaited(_attemptIceRestart());
      });
      _iceRestartTimer = restartTimer;
      _setState(
        state.value.copyWith(detail: 'Связь потеряна — переподключаем…'),
      );
    }
  }

  Future<void> _attemptIceRestart() async {
    final callId = _callId;
    final pc = _peerConnection;
    if (callId == null ||
        pc == null ||
        !_ownsActiveCall(callId) ||
        !_isIceRestartLeader ||
        _iceRestartInFlight ||
        _iceRestartAttempts >= 4) {
      return;
    }
    _iceRestartInFlight = true;
    _iceRestartAttempts++;
    final generation = ++_iceGeneration;
    try {
      final offer = await pc.createOffer({'iceRestart': true});
      if (!_ownsActiveCall(callId)) {
        if (_callId == callId) _iceRestartInFlight = false;
        return;
      }
      await pc.setLocalDescription(offer);
      if (!_ownsActiveCall(callId)) {
        if (_callId == callId) _iceRestartInFlight = false;
        return;
      }
      await _updateVerificationSdp(localSdp: offer.sdp);
      if (!_ownsActiveCall(callId)) {
        if (_callId == callId) _iceRestartInFlight = false;
        return;
      }
      _sendSignal({
        'kind': 'ice-restart-offer',
        'sdp': offer.sdp,
        'ice_generation': generation,
        'relay_only': false,
      });
      _localDescriptionSignaled = true;
      _flushLocalIce();
    } catch (error) {
      if (_callId != callId) return;
      appLog.warn('call', 'ICE restart failed: $error');
      _iceRestartInFlight = false;
      _scheduleIceRestartRetry(
        callId: callId,
        delay: const Duration(seconds: 1),
      );
      return;
    }
    late final Timer responseTimer;
    responseTimer = Timer(const Duration(seconds: 6), () {
      if (!identical(_iceRestartResponseTimer, responseTimer) ||
          _callId != callId ||
          _iceGeneration != generation) {
        return;
      }
      _iceRestartResponseTimer = null;
      if (!_ownsActiveCall(callId) || !_iceRestartInFlight) return;
      _iceRestartInFlight = false;
      _scheduleIceRestartRetry(
        callId: callId,
        delay: const Duration(seconds: 1),
      );
    });
    _iceRestartResponseTimer?.cancel();
    _iceRestartResponseTimer = responseTimer;
  }

  void _scheduleIceRestartRetry({
    required String callId,
    required Duration delay,
  }) {
    if (!_iceRecoveryActive ||
        !_ownsActiveCall(callId) ||
        !_isIceRestartLeader ||
        _iceRestartInFlight ||
        _iceRestartAttempts >= 4) {
      return;
    }
    _iceRestartTimer?.cancel();
    late final Timer restartTimer;
    restartTimer = Timer(delay, () {
      if (!identical(_iceRestartTimer, restartTimer) ||
          !_ownsActiveCall(callId)) {
        return;
      }
      _iceRestartTimer = null;
      if (_iceRecoveryActive && !_iceRestartInFlight) {
        unawaited(_attemptIceRestart());
      }
    });
    _iceRestartTimer = restartTimer;
  }

  void _flushLocalIce() {
    final queued = List<Map<String, dynamic>>.from(_localIceQueue);
    _localIceQueue.clear();
    for (final candidate in queued) {
      _sendSignal(candidate);
    }
  }

  RTCIceCandidate? _candidateFrom(Map<String, dynamic> data) {
    final value = data['candidate']?.toString();
    if (value == null || value.isEmpty) return null;
    return RTCIceCandidate(
      value,
      data['sdp_mid']?.toString(),
      _asInt(data['sdp_mline_index']),
    );
  }

  void _sendSignal(Map<String, dynamic> data) {
    final peer = _peer;
    final callId = _callId;
    if (peer == null || callId == null) return;
    _sendSignalTo(peer, <String, dynamic>{...data, 'call_id': callId});
  }

  void _sendSignalTo(String peer, Map<String, dynamic> data) {
    if (!WsClient.instance.isConnected) {
      appLog.warn('call', 'Call signaling skipped: websocket is disconnected');
      return;
    }
    WsClient.instance.send('call.signal', <String, dynamic>{
      'to': peer,
      ...data,
    });
  }

  Future<List<Map<String, dynamic>>> _loadIceServers() async {
    try {
      final response = await WsClient.instance.call(
        'call.ice',
        const <String, dynamic>{},
        const Duration(seconds: 4),
      );
      final raw = response['ice_servers'];
      if (raw is List) {
        final parsed = raw
            .whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .where((entry) => entry['urls'] != null)
            .toList();
        if (parsed.isNotEmpty) {
          _hasTurnServers = parsed.any(_containsTurnServer);
          return parsed;
        }
      }
    } catch (error) {
      appLog.warn(
        'call',
        'ICE config unavailable, using STUN fallback: $error',
      );
    }
    _hasTurnServers = false;
    return List<Map<String, dynamic>>.from(_defaultIceServers);
  }

  static bool _containsTurnServer(Map<String, dynamic> server) {
    final raw = server['urls'];
    final urls = raw is String
        ? <String>[raw]
        : raw is List
        ? raw.whereType<String>()
        : const <String>[];
    return urls.any(
      (url) =>
          url.toLowerCase().startsWith('turn:') ||
          url.toLowerCase().startsWith('turns:'),
    );
  }

  void _markConnected() {
    if (!isActive) return;
    _stopRingSound();
    _cancelRingTimer();
    _connectTimer?.cancel();
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    _connectedAt ??= DateTime.now();
    _setState(
      state.value.copyWith(phase: CallPhase.connected, clearDetail: true),
    );
    _startMediaRoutePolling();
    _durationTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final started = _connectedAt;
      if (started == null || !isActive) return;
      _setState(
        state.value.copyWith(duration: DateTime.now().difference(started)),
      );
    });
  }

  void _startMediaRoutePolling() {
    final callId = _callId;
    final pc = _peerConnection;
    if (callId == null || pc == null) return;
    _mediaRouteTimer?.cancel();
    unawaited(_updateMediaRoute(callId, pc));
    _mediaRouteTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_callId != callId || state.value.phase != CallPhase.connected) return;
      unawaited(_updateMediaRoute(callId, pc));
    });
  }

  Future<void> _updateMediaRoute(String callId, RTCPeerConnection pc) async {
    if (_routeStatsCallIdInFlight == callId) return;
    _routeStatsCallIdInFlight = callId;
    try {
      final reports = await pc.getStats();
      if (_callId != callId ||
          !identical(_peerConnection, pc) ||
          state.value.phase != CallPhase.connected) {
        return;
      }
      final normalizedReports = reports
          .map(
            (report) => <String, dynamic>{
              'id': report.id,
              'type': report.type,
              'values': report.values,
            },
          )
          .toList(growable: false);
      final route = resolveCallMediaRouteFromStats(normalizedReports);
      final latencyMs = resolveCallLatencyMsFromStats(normalizedReports);
      if (route != CallMediaRoute.unknown) _mediaRoute = route;
      if ((route != CallMediaRoute.unknown &&
              route != state.value.mediaRoute) ||
          (latencyMs != null && latencyMs != state.value.latencyMs)) {
        _setState(
          state.value.copyWith(
            mediaRoute: route == CallMediaRoute.unknown
                ? state.value.mediaRoute
                : route,
            latencyMs: latencyMs,
          ),
        );
      }
    } catch (_) {
      // Stats are best-effort and may be unavailable on older Android builds.
    } finally {
      if (_routeStatsCallIdInFlight == callId) {
        _routeStatsCallIdInFlight = null;
      }
    }
  }

  Future<void> _updateVerificationSdp({
    String? localSdp,
    String? remoteSdp,
  }) async {
    if (localSdp != null && localSdp.isNotEmpty) {
      _verificationLocalSdp = localSdp;
    }
    if (remoteSdp != null && remoteSdp.isNotEmpty) {
      _verificationRemoteSdp = remoteSdp;
    }
    final local = _verificationLocalSdp;
    final remote = _verificationRemoteSdp;
    if (local == null || remote == null) return;
    final revision = ++_verificationRevision;
    try {
      final emojis = await CallVerificationCode.fromDescriptions(
        localSdp: local,
        remoteSdp: remote,
      );
      if (revision != _verificationRevision || !isActive) return;
      _setState(state.value.copyWith(verificationEmojis: emojis));
    } catch (error) {
      appLog.warn('call', 'verification code failed: $error');
    }
  }

  void _armRingTimeout() {
    _cancelRingTimer();
    _ringTimer = Timer(const Duration(seconds: 45), () {
      if (state.value.phase == CallPhase.connecting ||
          state.value.phase == CallPhase.outgoing) {
        unawaited(end(signalKind: 'timeout'));
      }
    });
  }

  void _armIncomingTimeout() {
    _cancelRingTimer();
    _ringTimer = Timer(const Duration(seconds: 45), () {
      if (state.value.phase == CallPhase.incoming) {
        unawaited(end(signalKind: 'timeout'));
      }
    });
  }

  void _armConnectTimeout() {
    _connectTimer?.cancel();
    _relayFallbackTimer?.cancel();
    _connectTimer = Timer(const Duration(seconds: 30), () {
      if (state.value.phase == CallPhase.connecting) {
        unawaited(_fail('Не удалось установить соединение'));
      }
    });
    if (_hasTurnServers && _isIceRestartLeader) {
      _relayFallbackTimer = Timer(const Duration(seconds: 7), () {
        if (!isActive || _connectedAt != null || _iceRestartInFlight) return;
        _setState(
          state.value.copyWith(detail: 'P2P не установился — пробуем TURN…'),
        );
        unawaited(_attemptIceRestart());
      });
    }
  }

  Future<void> _fail(String message) async {
    if (!isActive) return;
    await end(notify: true, finalPhase: CallPhase.failed, error: message);
  }

  Future<void> _disposeMedia() async {
    final screen = _screenStream;
    for (final track in screen?.getTracks() ?? <MediaStreamTrack>[]) {
      track.onEnded = null;
      track.stop();
    }
    await screen?.dispose();
    final extraVideo = _extraVideoStream;
    for (final track in extraVideo?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    await extraVideo?.dispose();
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    await _localStream?.dispose();
    await _remoteStream?.dispose();
    _localStream = null;
    _extraVideoStream = null;
    _screenStream = null;
    _remoteStream = null;
    _videoSender = null;
    _videoTransceiver = null;
    _screenShareOwnsVideoTransceiver = false;
    await _stopScreenCaptureBackground();
  }

  void _cancelRingTimer() {
    _ringTimer?.cancel();
    _ringTimer = null;
  }

  void _cancelTimers() {
    _cancelRingTimer();
    _stopRingSound();
    _connectTimer?.cancel();
    _disconnectTimer?.cancel();
    _durationTimer?.cancel();
    _relayFallbackTimer?.cancel();
    _iceRestartTimer?.cancel();
    _iceRestartResponseTimer?.cancel();
    _mediaRouteTimer?.cancel();
    _connectTimer = null;
    _disconnectTimer = null;
    _durationTimer = null;
    _relayFallbackTimer = null;
    _iceRestartTimer = null;
    _iceRestartResponseTimer = null;
    _mediaRouteTimer = null;
  }

  void _startRingSound() {
    _stopRingSound();
    unawaited(GhostSoundEffects.instance.playCall());
    _ringSoundTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!isActive || state.value.phase == CallPhase.connected) {
        _stopRingSound();
        return;
      }
      unawaited(GhostSoundEffects.instance.playCall());
    });
  }

  void _stopRingSound() {
    _ringSoundTimer?.cancel();
    _ringSoundTimer = null;
    unawaited(GhostSoundEffects.instance.stopCall());
  }

  void _setState(CallSnapshot next) => state.value = next;

  void _resetNegotiationState({bool clearCandidates = true}) {
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    _iceRestartTimer?.cancel();
    _iceRestartTimer = null;
    _iceRestartResponseTimer?.cancel();
    _iceRestartResponseTimer = null;
    _iceRecoveryActive = false;
    _iceRestartInFlight = false;
    _iceRestartAttempts = 0;
    _remoteDescriptionReady = false;
    _localDescriptionSignaled = false;
    _localIceQueue.clear();
    if (clearCandidates) _pendingCandidates.clear();
    _iceGeneration = 0;
    _mediaRoute = CallMediaRoute.unknown;
    _verificationRevision++;
    _verificationLocalSdp = null;
    _verificationRemoteSdp = null;
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }

  static int _generationFrom(Map<String, dynamic> data) {
    final value = data['ice_generation'];
    if (value is int && value >= 0) return value;
    final parsed = int.tryParse('$value');
    return parsed == null ? 0 : parsed.clamp(0, 1 << 30).toInt();
  }

  static String _normalizePeer(String peer) => peer.trim().toLowerCase();

  static String _newCallId() =>
      'call_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  static String _friendlyError(Object error) {
    final message = error.toString().replaceFirst('Bad state: ', '');
    return message.isEmpty ? 'Не удалось начать звонок' : message;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
