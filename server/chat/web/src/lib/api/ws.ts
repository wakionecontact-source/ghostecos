type SocketState = 'closed' | 'connecting' | 'open';
type SocketHandler = (event: { type: string; data?: unknown }) => void;

const WS_PATH = '/api/chat/v2/client/ws';
const PING_INTERVAL = 30_000;

function socketUrl(): string {
  const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
  return `${scheme}://${location.host}${WS_PATH}`;
}

/** Real-time канал: сервер ждёт auth-фрейм, дальше события и ping/pong. */
export class ChatSocket {
  private ws: WebSocket | null = null;
  private state: SocketState = 'closed';
  private pingTimer: number | null = null;
  private reconnectTimer: number | null = null;
  private attempts = 0;
  private handlers = new Set<SocketHandler>();

  constructor(private readonly token: string) {}

  connect(): void {
    if (this.state !== 'closed') return;
    this.state = 'connecting';
    const ws = new WebSocket(socketUrl());
    this.ws = ws;

    ws.onopen = () => {
      this.state = 'open';
      this.attempts = 0;
      ws.send(JSON.stringify({ type: 'auth', token: this.token }));
      this.pingTimer = window.setInterval(() => ws.send('ping'), PING_INTERVAL);
      this.emit({ type: 'socket.open' });
    };

    ws.onmessage = (message) => {
      const raw = typeof message.data === 'string' ? message.data : '';
      if (!raw || raw === 'pong') return;
      try {
        const parsed = JSON.parse(raw) as { type?: string; data?: unknown };
        if (parsed.type) this.emit({ type: parsed.type, data: parsed.data });
      } catch {
        // Не-JSON кадры не должны ломать соединение.
      }
    };

    ws.onclose = () => {
      this.cleanup();
      this.emit({ type: 'socket.closed' });
      this.scheduleReconnect();
    };

    ws.onerror = () => ws.close();
  }

  close(): void {
    if (this.reconnectTimer !== null) window.clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    this.attempts = 0;
    this.ws?.close();
    this.cleanup();
  }

  /** Отправка кадра серверу — тот же формат {type, data}, что у приложения. */
  send(type: string, data?: Record<string, unknown>): void {
    if (this.state !== 'open' || !this.ws) return;
    this.ws.send(JSON.stringify(data ? { type, data } : { type }));
  }

  get isOpen(): boolean {
    return this.state === 'open';
  }

  on(handler: SocketHandler): () => void {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  private emit(event: { type: string; data?: unknown }): void {
    for (const handler of this.handlers) handler(event);
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer !== null) return;
    const delay = Math.min(30_000, 1000 * 2 ** this.attempts);
    this.attempts += 1;
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }

  private cleanup(): void {
    this.state = 'closed';
    if (this.pingTimer !== null) window.clearInterval(this.pingTimer);
    this.pingTimer = null;
    this.ws = null;
  }
}
