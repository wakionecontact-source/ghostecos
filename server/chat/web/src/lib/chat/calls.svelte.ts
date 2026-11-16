import type { ChatSocket } from '../api/ws';

/** Состояние звонка: как в приложении — один активный вызов на вкладку. */
export type CallStatus = 'idle' | 'outgoing' | 'incoming' | 'active' | 'ended';

interface SignalData {
  call_id?: string;
  kind?: string;
  from_username?: string;
  sdp?: string;
  candidate?: string;
  sdp_mid?: string;
  sdp_mline_index?: number;
  video?: boolean;
  error?: string;
}

const DEFAULT_ICE: RTCIceServer[] = [
  { urls: ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'] },
];

const RING_TIMEOUT = 45_000;

/** WebRTC-звонки 1:1: медиа идёт напрямую, сервер только пересылает сигналы. */
export class CallStore {
  status = $state<CallStatus>('idle');
  peer = $state('');
  callId = $state('');
  video = $state(false);
  muted = $state(false);
  error = $state('');
  startedAt = $state(0);
  remote = $state<MediaStream | null>(null);
  localVideo = $state(false);

  private socket: ChatSocket | null = null;
  private pc: RTCPeerConnection | null = null;
  private local: MediaStream | null = null;
  private ice: RTCIceServer[] = DEFAULT_ICE;
  private iceWaiters: Array<() => void> = [];
  private pendingOffer = '';
  private ringTimer: number | null = null;
  private unsubscribe: (() => void) | null = null;

  /** Подписка на кадры сокета; вызывается один раз при старте хранилища. */
  attach(socket: ChatSocket): () => void {
    this.socket = socket;
    const off = socket.on((event) => {
      if (event.type === 'call.ice.ok') {
        const data = event.data as { ice_servers?: RTCIceServer[] } | undefined;
        if (data?.ice_servers?.length) this.ice = data.ice_servers;
        this.flushIce();
        return;
      }
      if (event.type === 'call.signal') {
        void this.onSignal((event.data ?? {}) as SignalData);
        return;
      }
      if (event.type === 'call.signal.err') {
        const data = event.data as { error?: string } | undefined;
        if (data?.error) this.fail(data.error);
      }
    });
    this.unsubscribe = off;
    return () => {
      off();
      this.unsubscribe = null;
    };
  }

  private send(data: Record<string, unknown>): void {
    this.socket?.send('call.signal', data);
  }

  /** TURN-креды приходят только с сервера, поэтому ждём ответ, но не дольше 1.5 с. */
  private requestIce(callId: string): Promise<void> {
    return new Promise((resolve) => {
      this.iceWaiters.push(resolve);
      window.setTimeout(() => this.flushIce(), 1500);
      this.socket?.send('call.ice', { request_id: callId });
    });
  }

  private flushIce(): void {
    const waiters = this.iceWaiters;
    this.iceWaiters = [];
    for (const resolve of waiters) resolve();
  }

  private fail(text: string): void {
    this.error = text;
    void this.hangup();
  }

  private async media(video: boolean): Promise<MediaStream> {
    if (!navigator.mediaDevices?.getUserMedia) throw new Error('Браузер не даёт доступ к микрофону');
    return navigator.mediaDevices.getUserMedia({ audio: true, video });
  }

  private peerConnection(): RTCPeerConnection {
    const pc = new RTCPeerConnection({ iceServers: this.ice });
    pc.onicecandidate = (event) => {
      if (!event.candidate || !this.peer) return;
      this.send({
        to: this.peer,
        call_id: this.callId,
        kind: 'candidate',
        candidate: event.candidate.candidate,
        sdp_mid: event.candidate.sdpMid ?? undefined,
        sdp_mline_index: event.candidate.sdpMLineIndex ?? undefined,
      });
    };
    pc.ontrack = (event) => {
      this.remote = event.streams[0] ?? new MediaStream([event.track]);
    };
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === 'failed' || pc.connectionState === 'closed') {
        if (this.status === 'active') void this.hangup();
      }
    };
    return pc;
  }

  /** Исходящий вызов: спрашиваем ICE, поднимаем микрофон и отправляем offer. */
  async start(peer: string, video = false): Promise<void> {
    if (this.status !== 'idle' && this.status !== 'ended') return;
    this.error = '';
    this.peer = peer.trim().toLowerCase();
    this.video = video;
    this.callId = `c${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    this.status = 'outgoing';
    this.armRingTimeout();

    try {
      await this.requestIce(this.callId);
      this.local = await this.media(video);
      const pc = this.peerConnection();
      this.pc = pc;
      for (const track of this.local.getTracks()) pc.addTrack(track, this.local);
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      this.send({
        to: this.peer,
        call_id: this.callId,
        kind: 'offer',
        sdp: offer.sdp ?? '',
        video,
      });
    } catch (cause) {
      this.fail(cause instanceof Error ? cause.message : 'Не удалось начать звонок');
    }
  }

  /** Входящий принят: отвечаем на сохранённый offer. */
  async accept(): Promise<void> {
    if (this.status !== 'incoming' || !this.pendingOffer) return;
    this.clearRing();
    try {
      if (!this.socket) return;
      await this.requestIce(this.callId);
      this.local = await this.media(this.video);
      const pc = this.peerConnection();
      this.pc = pc;
      for (const track of this.local.getTracks()) pc.addTrack(track, this.local);
      await pc.setRemoteDescription({ type: 'offer', sdp: this.pendingOffer });
      const answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      this.send({
        to: this.peer,
        call_id: this.callId,
        kind: 'answer',
        sdp: answer.sdp ?? '',
      });
      this.pendingOffer = '';
      this.status = 'active';
      this.startedAt = Math.floor(Date.now() / 1000);
    } catch (cause) {
      this.fail(cause instanceof Error ? cause.message : 'Не удалось принять звонок');
    }
  }

  async reject(): Promise<void> {
    if (this.status !== 'incoming') return;
    this.send({ to: this.peer, call_id: this.callId, kind: 'reject' });
    this.reset();
  }

  async hangup(): Promise<void> {
    if (this.status === 'idle') return;
    this.send({ to: this.peer, call_id: this.callId, kind: 'hangup' });
    this.reset();
  }

  /** Микрофон без пересоздания соединения — как кнопка mute в приложении. */
  toggleMute(): void {
    const track = this.local?.getAudioTracks()[0];
    if (!track) return;
    track.enabled = !track.enabled;
    this.muted = !track.enabled;
  }

  toggleVideo(): void {
    const track = this.local?.getVideoTracks()[0];
    if (!track) return;
    track.enabled = !track.enabled;
    this.localVideo = track.enabled;
  }

  private async onSignal(data: SignalData): Promise<void> {
    const kind = data.kind ?? '';
    const from = (data.from_username ?? '').toLowerCase();

    if (kind === 'offer') {
      if (this.status === 'active' || this.status === 'outgoing') {
        this.send({ to: from, call_id: data.call_id ?? '', kind: 'busy' });
        return;
      }
      this.peer = from;
      this.callId = data.call_id ?? '';
      this.video = !!data.video;
      this.pendingOffer = data.sdp ?? '';
      this.status = 'incoming';
      this.armRingTimeout();
      return;
    }

    if (data.call_id && this.callId && data.call_id !== this.callId) return;

    if (kind === 'ringing') {
      // Сервер уже подтвердил доставку — ждём ответа.
      return;
    }

    if (kind === 'answer') {
      this.clearRing();
      if (!this.pc || !data.sdp) return;
      await this.pc.setRemoteDescription({ type: 'answer', sdp: data.sdp });
      this.status = 'active';
      this.startedAt = Math.floor(Date.now() / 1000);
      return;
    }

    if (kind === 'candidate') {
      if (!this.pc || !data.candidate) return;
      try {
        await this.pc.addIceCandidate({
          candidate: data.candidate,
          sdpMid: data.sdp_mid,
          sdpMLineIndex: data.sdp_mline_index,
        });
      } catch {
        // Поздний кандидат после закрытия соединения не ломает звонок.
      }
      return;
    }

    if (kind === 'hangup' || kind === 'reject' || kind === 'busy' || kind === 'timeout') {
      this.error = kind === 'busy' ? 'Абонент занят' : kind === 'reject' ? 'Звонок отклонён' : '';
      this.reset();
    }
  }

  private armRingTimeout(): void {
    this.clearRing();
    this.ringTimer = window.setTimeout(() => {
      if (this.status === 'incoming' || this.status === 'outgoing') {
        this.send({ to: this.peer, call_id: this.callId, kind: 'timeout' });
        this.error = 'Нет ответа';
        this.reset();
      }
    }, RING_TIMEOUT);
  }

  private clearRing(): void {
    if (this.ringTimer !== null) window.clearTimeout(this.ringTimer);
    this.ringTimer = null;
  }

  private reset(): void {
    this.clearRing();
    this.pc?.close();
    this.pc = null;
    for (const track of this.local?.getTracks() ?? []) track.stop();
    this.local = null;
    this.remote = null;
    this.pendingOffer = '';
    this.muted = false;
    this.localVideo = false;
    this.startedAt = 0;
    this.status = this.error ? 'ended' : 'idle';
  }

  /** Закрываем за собой всё при уходе со страницы. */
  dispose(): void {
    if (this.status !== 'idle') this.send({ to: this.peer, call_id: this.callId, kind: 'hangup' });
    this.reset();
    this.unsubscribe?.();
    this.socket = null;
  }
}
