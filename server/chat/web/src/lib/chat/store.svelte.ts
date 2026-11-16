import { chatApi, type ChatClient, type Contact, type RoomSummary } from '../api/chat';
import { ChatSocket } from '../api/ws';
import { CallStore } from './calls.svelte';
import type { AccountKey } from '../crypto/account-key';
import { loadPrefs } from '../ui/prefs';
import { v2FromDevice, type V2Keys } from './keys';
import {
  listRooms,
  loadRoom,
  roomMembers,
  sendRoomMessage,
  type RoomMessage,
} from './rooms';
import {
  clearThread,
  downloadAttachment,
  getThread,
  listThreads,
  markPeerRead,
  receivePending,
  receiveV2,
  sendFile,
  sendText,
  setStatuses,
  syncHistory,
  syncStatuses,
  type FilePayload,
  type MessageStatus,
  type StoredMessage,
  type ThreadSummary,
} from './messages';

const REFRESH_INTERVAL = 60_000;
const HISTORY_INTERVAL = 45_000;
const PRESENCE_DEBOUNCE = 3_000;

export interface ChatPeer {
  username: string;
  title: string;
  preview: string;
  ts: number;
  mine: boolean;
  status?: MessageStatus;
}

/** Состояние чатов и realtime-канала: одно на всё приложение, как в мобильном клиенте. */
export class ChatStore {
  readonly account: AccountKey;

  contacts = $state<Contact[]>([]);
  threads = $state<ThreadSummary[]>([]);
  rooms = $state<RoomSummary[]>([]);
  roomsLoading = $state(false);
  /** Звонки живут на том же сокете, что и сообщения. */
  readonly calls = new CallStore();
  presence = $state<Record<string, boolean>>({});
  online = $state(false);
  ready = $state(false);
  error = $state('');
  unread = $state<Record<string, number>>({});

  private readonly api: ChatClient;
  private readonly token: string;
  private v2: V2Keys | null;
  private readonly username: string;
  private socket: ChatSocket | null = null;
  private timer: number | null = null;
  private busy = false;
  private watching = '';
  private asked = new Map<string, number>();
  private listeners = new Set<() => void>();
  private historyAt = 0;
  private lastRead = loadReadMarks();

  constructor(token: string, account: AccountKey, v2: V2Keys | null, username: string) {
    this.api = chatApi(token);
    this.token = token;
    this.account = account;
    this.v2 = v2;
    this.username = username;
  }

  /** Собеседники: контакты плюс те, с кем уже есть переписка. */
  get peers(): ChatPeer[] {
    const map = new Map<string, ChatPeer>();
    for (const contact of this.contacts) {
      map.set(contact.username, {
        username: contact.username,
        title: contact.display_name || contact.username,
        preview: '',
        ts: 0,
        mine: false,
      });
    }
    for (const thread of this.threads) {
      const known = map.get(thread.peer);
      map.set(thread.peer, {
        username: thread.peer,
        title: known?.title ?? thread.peer,
        preview: thread.lastText,
        ts: thread.lastTs,
        mine: thread.mine,
        status: thread.status,
      });
    }
    return [...map.values()].sort((a, b) => b.ts - a.ts);
  }

  titleOf(username: string): string {
    const peer = this.peers.find((item) => item.username === username);
    return peer?.title ?? username;
  }

  /** Подписка на события чата — экран треда перечитывает переписку. */
  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  start(): () => void {
    let alive = true;

    const socket = new ChatSocket(this.token);
    this.socket = socket;
    const offCalls = this.calls.attach(socket);
    const off = socket.on((event) => {
      if (!alive) return;
      if (event.type === 'socket.open') {
        this.online = true;
        this.askPresence(this.watching, true);
        void this.refresh();
        return;
      }
      if (event.type === 'socket.closed') {
        this.online = false;
        this.presence = {};
        return;
      }
      if (event.type === 'presence') {
        const data = event.data as { username?: string; online?: boolean } | undefined;
        if (data?.username) this.presence = { ...this.presence, [data.username]: !!data.online };
        return;
      }
      if (event.type === 'chat.delivered' || event.type === 'chat.read') {
        const data = event.data as { ids?: number[] } | undefined;
        const ids = (data?.ids ?? []).filter((id): id is number => typeof id === 'number');
        const status = event.type === 'chat.read' ? 'read' : 'delivered';
        void setStatuses(ids, status).then(() => this.notify());
        return;
      }
      if (event.type === 'chat.v2.new' || event.type === 'chat.new' || event.type === 'chat.echo' || event.type === 'chat.sealed_new') {
        void this.syncNew();
        return;
      }
      if (event.type === 'hello') void this.refresh();
    });
    socket.connect();

    this.api
      .contacts()
      .then((list) => {
        if (alive) this.contacts = list;
      })
      .catch(() => {
        // Контакты не должны блокировать историю.
      });

    // Сначала локальная история, потом серверная синхронизация.
    void (async () => {
      this.threads = await listThreads();
      this.ready = true;
      void this.refresh();
    })();

    this.timer = window.setInterval(() => void this.refresh(), REFRESH_INTERVAL);

    return () => {
      alive = false;
      off();
      offCalls();
      this.calls.dispose();
      socket.close();
      this.socket = null;
      if (this.timer !== null) window.clearInterval(this.timer);
      this.timer = null;
    };
  }

  /** Как в приложении: presence спрашиваем не чаще раза в 3 секунды. */
  askPresence(peer: string, force = false): void {
    if (!peer) return;
    this.watching = peer;
    const last = this.asked.get(peer) ?? 0;
    if (!force && Date.now() - last < PRESENCE_DEBOUNCE) return;
    this.asked.set(peer, Date.now());
    this.socket?.send('presence.ask', { username: peer });
  }

  /** Быстрая синхронизация по WS-событию: только новые сообщения и статусы. */
  private async syncNew(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      let added = 0;
      const v2 = await this.ensureV2();
      if (v2) added += (await receiveV2(this.api, v2)).added;
      added += (await receivePending(this.api, this.account, this.username)).added;
      await syncStatuses(this.api);
      this.threads = await listThreads();
      if (added > 0) this.notifyIncoming(added);
      this.error = '';
    } catch (cause) {
      this.error = cause instanceof Error ? cause.message : 'Ошибка синхронизации';
    } finally {
      this.busy = false;
      this.ready = true;
      this.notify();
    }
  }

  async refresh(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      let added = 0;
      const v2 = await this.ensureV2();
      if (v2) added += (await receiveV2(this.api, v2)).added;
      added += (await receivePending(this.api, this.account, this.username)).added;
      if (Date.now() - this.historyAt > HISTORY_INTERVAL) {
        this.historyAt = Date.now();
        await syncHistory(this.api, this.account, this.username);
      }
      await syncStatuses(this.api);
      this.threads = await listThreads();
      await this.recountUnread();
      // Точки присутствия в списке — как в приложении, с дебаунсом на пира.
      for (const item of this.peers.slice(0, 12)) this.askPresence(item.username);
      if (added > 0) this.notifyIncoming(added);
      this.error = '';
    } catch (cause) {
      this.error = cause instanceof Error ? cause.message : 'Ошибка синхронизации';
    } finally {
      this.busy = false;
      this.ready = true;
      this.notify();
    }
  }

  /** Системное уведомление о новых сообщениях — только когда вкладка не видна. */
  private notifyIncoming(added: number): void {
    if (!loadPrefs().notifications) return;
    if (typeof Notification === 'undefined' || Notification.permission !== 'granted') return;
    if (!document.hidden) return;
    const thread = this.threads[0];
    const title = thread ? this.titleOf(thread.peer) : 'GhostChat';
    const body = added === 1 ? 'Новое сообщение' : `Новых сообщений: ${added}`;
    try {
      const note = new Notification(title, { body, tag: 'ghostchat', silent: false });
      note.onclick = () => {
        window.focus();
        note.close();
      };
    } catch {
      // Уведомление не критично для работы чата.
    }
  }

  async openThread(peer: string): Promise<StoredMessage[]> {
    this.askPresence(peer, true);
    const list = await getThread(peer);
    this.markRead(peer);
    void markPeerRead(this.api, peer).catch(() => {});
    return list;
  }

  /** Локальная отметка чтения: счётчик непрочитанных как в списке приложения. */
  markRead(peer: string): void {
    this.lastRead.set(peer, Math.floor(Date.now() / 1000));
    saveReadMarks(this.lastRead);
    if (this.unread[peer]) this.unread = { ...this.unread, [peer]: 0 };
  }

  private async recountUnread(): Promise<void> {
    const counts: Record<string, number> = {};
    for (const thread of this.threads) {
      const since = this.lastRead.get(thread.peer) ?? 0;
      let total = 0;
      for (const message of await getThread(thread.peer)) {
        if (!message.mine && message.ts > since) total += 1;
      }
      if (total > 0) counts[thread.peer] = total;
    }
    this.unread = counts;
  }

  async loadThread(peer: string): Promise<StoredMessage[]> {
    return getThread(peer);
  }

  /** Ключи v2 из хранилища устройства — если при входе их не было под рукой. */
  private async ensureV2(): Promise<V2Keys | null> {
    if (this.v2) return this.v2;
    this.v2 = await v2FromDevice().catch(() => null);
    return this.v2;
  }

  async send(peer: string, text: string): Promise<void> {
    await sendText({ api: this.api, account: this.account, v2: await this.ensureV2() }, peer, text);
    this.threads = await listThreads();
    this.notify();
  }

  /** Вложение уходит зашифрованным; ключ остаётся в E2E-конверте. */
  async sendFile(peer: string, file: File, caption = ''): Promise<void> {    await sendFile(
      { api: this.api, account: this.account, v2: await this.ensureV2() },
      peer,
      file,
      caption,
    );
    this.threads = await listThreads();
    this.notify();
  }

  async download(file: FilePayload): Promise<{ blob: Blob; name: string }> {
    return downloadAttachment(this.api, file);
  }

  async addContact(username: string): Promise<void> {
    await this.api.addContact(username);
    this.contacts = await this.api.contacts();
  }

  async removeContact(username: string): Promise<void> {
    await this.api.removeContact(username);
    this.contacts = await this.api.contacts();
  }

  async block(username: string): Promise<void> {
    await this.api.block(username);
    this.contacts = await this.api.contacts();
  }

  async clearChat(peer: string): Promise<void> {
    await clearThread(this.api, peer);
    this.threads = await listThreads();
    this.unread = { ...this.unread, [peer]: 0 };
    this.notify();
  }

  /* ── Группы и каналы ─────────────────────────── */

  /** Список моих групп и каналов; тянем при входе и по кнопке обновления. */
  async loadRooms(): Promise<RoomSummary[]> {
    if (this.roomsLoading) return this.rooms;
    this.roomsLoading = true;
    try {
      this.rooms = await listRooms(this.api);
      return this.rooms;
    } finally {
      this.roomsLoading = false;
    }
  }

  /** Лента комнаты: конверты открываются ключом текущего устройства. */
  async openRoom(room: RoomSummary): Promise<RoomMessage[]> {
    return loadRoom(this.api, await this.ensureV2(), room, this.username);
  }

  async sendRoom(room: RoomSummary, text: string): Promise<void> {
    await sendRoomMessage(this.api, await this.ensureV2(), room, this.username, text);
    this.notify();
  }

  /** Создание группы или канала: набор полей один, различается только маршрут. */
  async createRoom(
    kind: 'group' | 'channel',
    username: string,
    title: string,
  ): Promise<RoomSummary> {
    const body = {
      username: username.trim().replace(/^@/, ''),
      title: title.trim(),
    };
    const room =
      kind === 'channel' ? await this.api.createChannel(body) : await this.api.createGroup(body);
    await this.loadRooms();
    return room;
  }

  roomMembersOf(room: RoomSummary) {
    return roomMembers(this.api, room);
  }

  private notify(): void {
    for (const listener of this.listeners) listener();
  }
}

const READ_KEY = 'gc.web.readmarks';

function loadReadMarks(): Map<string, number> {
  try {
    const raw = localStorage.getItem(READ_KEY);
    if (!raw) return new Map();
    const parsed = JSON.parse(raw) as Record<string, number>;
    return new Map(Object.entries(parsed));
  } catch {
    return new Map();
  }
}

function saveReadMarks(marks: Map<string, number>): void {
  try {
    localStorage.setItem(READ_KEY, JSON.stringify(Object.fromEntries(marks)));
  } catch {
    // Приватный режим может запрещать запись.
  }
}


