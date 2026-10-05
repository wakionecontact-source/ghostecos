import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
    this.muted = false,
    this.speaker = false,
    this.cameraEnabled = true,
    this.localStream,
    this.remoteStream,
    this.duration = Duration.zero,
    this.connectionState = 'new',
    this.error,
    this.detail,
    this.mediaRoute = CallMediaRoute.unknown,
    this.verificationEmojis = const [],
  });

  final CallPhase phase;
  final String? peer;
  final String? callId;
  final bool video;
  final bool muted;
  final bool speaker;
  final bool cameraEnabled;
  final MediaStream? localStream;
  final MediaStream? remoteStream;
  final Duration duration;
  final String connectionState;
  final String? error;
  final String? detail;
  final CallMediaRoute mediaRoute;
  final List<String> verificationEmojis;

  CallSnapshot copyWith({
    CallPhase? phase,
    String? peer,
    String? callId,
    bool? video,
    bool? muted,
    bool? speaker,
    bool? cameraEnabled,
    MediaStream? localStream,
    MediaStream? remoteStream,
    Duration? duration,
    String? connectionState,
    String? error,
    String? detail,
    CallMediaRoute? mediaRoute,
    List<String>? verificationEmojis,
    bool clearDetail = false,
  }) {
    return CallSnapshot(
      phase: phase ?? this.phase,
      peer: peer ?? this.peer,
      callId: callId ?? this.callId,
      video: video ?? this.video,
      muted: muted ?? this.muted,
      speaker: speaker ?? this.speaker,
      cameraEnabled: cameraEnabled ?? this.cameraEnabled,
      localStream: localStream ?? this.localStream,
      remoteStream: remoteStream ?? this.remoteStream,
      duration: duration ?? this.duration,
      connectionState: connectionState ?? this.connectionState,
      error: error ?? this.error,
      detail: clearDetail ? null : detail ?? this.detail,
      mediaRoute: mediaRoute ?? this.mediaRoute,
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
  Timer? _mediaRouteTimer;
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
    _muted = false;
    _speaker = false;
    _cameraEnabled = true;
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
    _muted = false;
    _speaker = false;
    _cameraEnabled = true;
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
    if (!_currentVideo) return;
    _cameraEnabled = !_cameraEnabled;
    for (final track
        in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = _cameraEnabled;
    }
    _setState(state.value.copyWith(cameraEnabled: _cameraEnabled));
  }

  Future<void> switchCamera() async {
    if (!_currentVideo) return;
    final track = _localStream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    await Helper.switchCamera(track);
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
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            _beginIceRecovery();
            _disconnectTimer?.cancel();
            _disconnectTimer = Timer(const Duration(seconds: 10), () {
              if (state.value.connectionState ==
                  RTCPeerConnectionState
                      .RTCPeerConnectionStateDisconnected
                      .name) {
                unawaited(_fail('Соединение с собеседником потеряно'));
              }
            });
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
      await connection.addTrack(track, stream);
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
      _currentVideo = data['video'] == true;
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
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      await _updateVerificationSdp(remoteSdp: sdp);
      _remoteDescriptionReady = true;
      await _flushCandidates(callId);
      _setState(state.value.copyWith(detail: 'Связь восстановлена'));
    } catch (error) {
      appLog.warn('call', 'ICE restart answer apply failed: $error');
    }
  }

  void _beginIceRecovery() {
    if (!isActive || _ending || _iceRestartInFlight) return;
    _iceRecoveryActive = true;
    _disconnectTimer?.cancel();
    _disconnectTimer = Timer(const Duration(seconds: 25), () {
      if (_iceRecoveryActive && isActive) {
        unawaited(_fail('Соединение с собеседником потеряно'));
      }
    });
    if (_isIceRestartLeader && _iceRestartTimer?.isActive != true) {
      final initialNegotiation = state.value.phase == CallPhase.connecting;
      final delay = initialNegotiation && _hasTurnServers
          ? const Duration(seconds: 7)
          : const Duration(seconds: 1);
      _iceRestartTimer = Timer(delay, () {
        _iceRestartTimer = null;
        unawaited(_attemptIceRestart());
      });
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
    _iceGeneration++;
    try {
      final offer = await pc.createOffer({'iceRestart': true});
      if (!_ownsActiveCall(callId)) return;
      await pc.setLocalDescription(offer);
      await _updateVerificationSdp(localSdp: offer.sdp);
      _sendSignal({
        'kind': 'ice-restart-offer',
        'sdp': offer.sdp,
        'ice_generation': _iceGeneration,
        'relay_only': false,
      });
      _localDescriptionSignaled = true;
      _flushLocalIce();
    } catch (error) {
      appLog.warn('call', 'ICE restart failed: $error');
    } finally {
      _iceRestartInFlight = false;
    }
    if (_iceRecoveryActive && isActive && _iceRestartAttempts < 4) {
      _iceRestartTimer?.cancel();
      _iceRestartTimer = Timer(const Duration(seconds: 3), () {
        _iceRestartTimer = null;
        unawaited(_attemptIceRestart());
      });
    }
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
      final route = resolveCallMediaRouteFromStats(
        reports
            .map(
              (report) => <String, dynamic>{
                'id': report.id,
                'type': report.type,
                'values': report.values,
              },
            )
            .toList(),
      );
      if (route != CallMediaRoute.unknown && route != _mediaRoute) {
        _mediaRoute = route;
        _setState(state.value.copyWith(mediaRoute: route));
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
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    await _localStream?.dispose();
    await _remoteStream?.dispose();
    _localStream = null;
    _remoteStream = null;
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
    _mediaRouteTimer?.cancel();
    _connectTimer = null;
    _disconnectTimer = null;
    _durationTimer = null;
    _relayFallbackTimer = null;
    _iceRestartTimer = null;
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
