import type { ChatClient, InboxMessage, PeerKeys } from '../api/chat';
import { ApiError } from '../api/http';
import type { AccountKey } from '../crypto/account-key';
import { aesGcmDecrypt } from '../crypto/aes';
import { attachmentBlobBytes, encryptAttachment } from '../crypto/attachment';
import { fromBase64, toBase64, utf8 } from '../crypto/bytes';
import { decryptDm, encryptDm } from '../crypto/dm';
import { decryptForMe, encryptV2 } from '../crypto/envelope';
import { idbGet, idbPut, STORE_MESSAGES } from '../storage/db';
import { scopeSuffix } from '../auth/scope';
import { toUnixSeconds } from './time';
import { identityPubB64, trustedPeerDevice, v2FromDevice, type V2Keys } from './keys';

export type MessageStatus = 'pending' | 'saved' | 'delivered' | 'read';

/** Вложение: ключ и iv едут только внутри E2E-конверта, blob — на сервере. */
export interface FilePayload {
  file_id: number;
  file_name: string;
  mime: string;
  size: number;
  key: string;
  iv: string;
  voice?: boolean;
  duration?: number;
  thumb?: string;
}

export interface StoredMessage {
  /** Ключ записи: история, конверт v2 и легаси-очередь не пересекаются. */
  uid: string;
  /** Серверный id для статусов доставки (0, если сервер его не сообщил). */
  sid: number;
  peer: string;
  text: string;
  mine: boolean;
  ts: number;
  status?: MessageStatus;
  file?: FilePayload;
}

interface WirePayload {
  type?: string;
  text?: string;
  v?: number;
  from_id?: string;
  sid?: number;
  ts?: number;
  peer_hint?: string;
  file_id?: number;
  file_name?: string;
  mime?: string;
  size?: number;
  key?: string;
  iv?: string;
  voice?: boolean;
  duration?: number;
  thumb?: string;
}

/** История у каждого аккаунта своя: смена аккаунта не подмешивает чужое и не стирает. */
function keyOf(name: string): string {
  return `${scopeSuffix()}|${name}`;
}

function threadKey(peer: string): string {
  return keyOf(`thread:${peer.trim().toLowerCase()}`);
}

export interface ThreadSummary {
  peer: string;
  lastText: string;
  lastTs: number;
  mine: boolean;
  status?: MessageStatus;
}

const INDEX_KEY = 'thread-index';
const HISTORY_CURSOR = 'history-cursor';
/** Отметки «чат очищен»: старая история не должна всплывать из серверной синхронизации. */
const CLEAR_MARKS = 'clear-marks';
const peerPubCache = new Map<string, Uint8Array>();

async function clearedAt(peer: string): Promise<number> {
  const marks = (await idbGet<Record<string, number>>(STORE_MESSAGES, keyOf(CLEAR_MARKS))) ?? {};
  return marks[peer] ?? 0;
}

/** Полная очистка переписки: серверный буфер, локальная история и маска старых сообщений. */
export async function clearThread(api: ChatClient, peer: string): Promise<void> {
  const trimmed = peer.trim().toLowerCase();
  try {
    await api.clearChatWith(trimmed);
  } catch {
    // Буфер мог уже опустеть — локальную очистку всё равно выполняем.
  }
  await idbPut(STORE_MESSAGES, threadKey(trimmed), []);
  const index = (await idbGet<ThreadSummary[]>(STORE_MESSAGES, keyOf(INDEX_KEY))) ?? [];
  await idbPut(STORE_MESSAGES, keyOf(INDEX_KEY), index.filter((item) => item.peer !== trimmed));
  const marks = (await idbGet<Record<string, number>>(STORE_MESSAGES, keyOf(CLEAR_MARKS))) ?? {};
  marks[trimmed] = Math.floor(Date.now() / 1000);
  await idbPut(STORE_MESSAGES, keyOf(CLEAR_MARKS), marks);
}

export async function getThread(peer: string): Promise<StoredMessage[]> {
  const list = (await idbGet<StoredMessage[]>(STORE_MESSAGES, threadKey(peer))) ?? [];
  // Старые записи могли лечь с нечисловым временем — приводим на чтении.
  return list.map((item) => ({ ...item, ts: toUnixSeconds(item.ts) }));
}

export async function listThreads(): Promise<ThreadSummary[]> {
  const index = (await idbGet<ThreadSummary[]>(STORE_MESSAGES, keyOf(INDEX_KEY))) ?? [];
  return index
    .map((item) => ({ ...item, lastTs: toUnixSeconds(item.lastTs) }))
    .sort((a, b) => b.lastTs - a.lastTs);
}

async function touchIndex(message: StoredMessage): Promise<void> {
  const index = (await idbGet<ThreadSummary[]>(STORE_MESSAGES, keyOf(INDEX_KEY))) ?? [];
  const next = index.filter((item) => item.peer !== message.peer);
  next.push({
    peer: message.peer,
    lastText: message.text,
    lastTs: message.ts,
    mine: message.mine,
    status: message.status,
  });
  await idbPut(STORE_MESSAGES, keyOf(INDEX_KEY), next);
}

async function appendMessage(message: StoredMessage): Promise<boolean> {
  if (!message.mine) {
    const mark = await clearedAt(message.peer);
    if (mark > 0 && message.ts < mark) return false;
  }
  const thread = await getThread(message.peer);
  const existing = thread.find((item) => item.uid === message.uid);
  if (existing) {
    // Догоняем поля, если запись легла раньше с пустым временем или статусом.
    let changed = false;
    if (existing.ts !== message.ts) {
      existing.ts = message.ts;
      changed = true;
    }
    if (existing.text !== message.text) {
      existing.text = message.text;
      changed = true;
    }
    if (message.status && !existing.status) {
      existing.status = message.status;
      changed = true;
    }
    if (changed) {
      thread.sort((a, b) => a.ts - b.ts || a.uid.localeCompare(b.uid));
      await idbPut(STORE_MESSAGES, threadKey(message.peer), thread);
      await touchIndex(message);
    }
    return false;
  }
  thread.push(message);
  thread.sort((a, b) => a.ts - b.ts || a.uid.localeCompare(b.uid));
  await idbPut(STORE_MESSAGES, threadKey(message.peer), thread);
  await touchIndex(message);
  return true;
}

async function peerPublicKey(api: ChatClient, peer: string): Promise<Uint8Array> {
  const cached = peerPubCache.get(peer);
  if (cached) return cached;
  const record = await api.peerPub(peer);
  if (!record.x25519_pub) throw new Error('У получателя ещё нет ключей GhostChat');
  const raw = fromBase64(record.x25519_pub);
  if (raw.length !== 65) throw new Error('Неизвестный формат ключа получателя');
  peerPubCache.set(peer, raw);
  return raw;
}

/* ── Отправка ────────────────────────────────────────── */

export interface SendContext {
  api: ChatClient;
  account: AccountKey;
  v2: V2Keys | null;
}

async function sendV2(
  api: ChatClient,
  keys: V2Keys,
  toUsername: string,
  text: string,
): Promise<StoredMessage> {
  const payload: WirePayload = {
    v: 2,
    type: 'msg',
    text,
    ts: Math.floor(Date.now() / 1000),
  };
  const sent = await deliverV2(api, keys, toUsername, payload);
  const message: StoredMessage = {
    uid: `v2s-${sent.sid}`,
    sid: 0,
    peer: toUsername,
    text,
    mine: true,
    ts: sent.ts,
    status: sent.delivered > 0 ? 'saved' : 'pending',
  };
  await appendMessage(message);
  return message;
}

interface Delivered {
  sid: number;
  delivered: number;
  ts: number;
}

/** Собирает конверты по доверенным устройствам пира и отправляет payload. */
/** Ключи пира меняются редко — держим их в памяти, чтобы не тратить RTT на каждое сообщение. */
const PEER_KEYS_TTL = 60_000;
const peerKeysCache = new Map<string, { bundle: PeerKeys; at: number }>();

async function peerBundle(api: ChatClient, username: string, force = false): Promise<PeerKeys> {
  const key = username.trim().toLowerCase();
  const hit = peerKeysCache.get(key);
  if (!force && hit && Date.now() - hit.at < PEER_KEYS_TTL) return hit.bundle;
  const bundle = await api.peerKeys(username);
  peerKeysCache.set(key, { bundle, at: Date.now() });
  return bundle;
}

async function deliverV2(
  api: ChatClient,
  keys: V2Keys,
  toUsername: string,
  payload: WirePayload,
): Promise<Delivered> {
  const sid = Date.now() * 1000 + Math.floor(Math.random() * 1000);
  const ts = payload.ts ?? Math.floor(Date.now() / 1000);
  const wire: WirePayload = { ...payload, v: 2, from_id: identityPubB64(keys), sid, ts };
  const plain = utf8(JSON.stringify(wire));

  let bundle = await peerBundle(api, toUsername);
  for (let attempt = 0; ; attempt += 1) {
    if (!bundle.identity_pub || bundle.devices.length === 0) throw new Error('NO_V2');
    const envelopes: { target_device_id: number; envelope: string }[] = [];
    for (const device of bundle.devices) {
      if (!trustedPeerDevice(bundle.identity_pub, device.device_pub, device.signed_prekey_sig)) continue;
      const envelope = await encryptV2(fromBase64(device.device_pub), plain);
      envelopes.push({ target_device_id: device.device_id, envelope });
    }
    if (envelopes.length === 0) throw new Error('NO_V2');
    try {
      const result = await api.sendV2({ to_username: toUsername, envelopes });
      return { sid, delivered: result.delivered_to_devices, ts };
    } catch (cause) {
      // 409 — у пира сменился ключ устройства: перечитываем бандл один раз.
      if (attempt === 0 && cause instanceof ApiError && cause.status === 409) {
        bundle = await peerBundle(api, toUsername, true);
        continue;
      }
      throw cause;
    }
  }
}

/** Легаси-путь приложения: P-256 ECDH в /api/chat/send, пока у пира нет v2-устройств. */
async function sendLegacy(
  api: ChatClient,
  account: AccountKey,
  peer: string,
  text: string,
): Promise<StoredMessage> {
  const pub = await peerPublicKey(api, peer);
  const payload: WirePayload = { type: 'msg', text };
  const ciphertext = await encryptDm(account.cryptoKey, pub, JSON.stringify(payload));
  const result = await api.sendDm({ to_username: peer, ciphertext });

  const message: StoredMessage = {
    uid: `l${result.id}`,
    sid: result.id,
    peer,
    text,
    mine: true,
    ts: toUnixSeconds(result.created_at),
    status: result.recipient_online ? 'delivered' : 'pending',
  };
  await appendMessage(message);
  return message;
}

/** Отправка как в приложении: v2 при наличии устройств, иначе легаси /send. */
export async function sendText(ctx: SendContext, toUsername: string, text: string): Promise<StoredMessage> {
  const peer = toUsername.trim().toLowerCase();
  const trimmed = text.trim();
  if (!trimmed) throw new Error('Пустое сообщение');

  const keys = ctx.v2 ?? (await v2FromDevice());
  if (keys) {
    try {
      return await sendV2(ctx.api, keys, peer, trimmed);
    } catch (cause) {
      if (!(cause instanceof Error) || cause.message !== 'NO_V2') throw cause;
    }
  }
  return sendLegacy(ctx.api, ctx.account, peer, trimmed);
}

/** Вложение: шифруем у себя, грузим blob, ключ отправляем только в E2E-конверте. */
export async function sendFile(
  ctx: SendContext,
  toUsername: string,
  file: File,
  caption = '',
): Promise<StoredMessage> {
  const peer = toUsername.trim().toLowerCase();
  const keys = ctx.v2 ?? (await v2FromDevice());
  if (!keys) throw new Error('Ключ устройства не найден — разблокируй аккаунт заново');

  const plain = new Uint8Array(await file.arrayBuffer());
  const sealed = await encryptAttachment(plain);
  const uploaded = await ctx.api.uploadFile(peer, attachmentBlobBytes(sealed));

  const payload: WirePayload = {
    type: 'file',
    text: caption.trim(),
    file_id: uploaded.file_id,
    file_name: file.name,
    mime: file.type || 'application/octet-stream',
    size: plain.length,
    key: sealed.key,
    iv: sealed.iv,
    ts: Math.floor(Date.now() / 1000),
  };
  const sent = await deliverV2(ctx.api, keys, peer, payload);
  const message: StoredMessage = {
    uid: `v2s-${sent.sid}`,
    sid: 0,
    peer,
    text: caption.trim(),
    mine: true,
    ts: sent.ts,
    status: sent.delivered > 0 ? 'saved' : 'pending',
    file: {
      file_id: uploaded.file_id,
      file_name: file.name,
      mime: payload.mime ?? 'application/octet-stream',
      size: plain.length,
      key: sealed.key,
      iv: sealed.iv,
    },
  };
  await appendMessage(message);
  return message;
}

/** Скачивает и расшифровывает вложение. Ack не шлём: браузер может открыть файл повторно. */
export async function downloadAttachment(
  api: ChatClient,
  file: FilePayload,
): Promise<{ blob: Blob; name: string }> {
  const sealed = await api.downloadFile(file.file_id);
  const key = fromBase64(file.key);
  const iv = fromBase64(file.iv);
  const plain = await aesGcmDecrypt(key, iv, sealed);
  const bytes = new Uint8Array(plain.length);
  bytes.set(plain);
  return { blob: new Blob([bytes], { type: file.mime || 'application/octet-stream' }), name: file.file_name };
}

/** Файловые поля payload → вложение; для обычных сообщений возвращает null. */
function fileFromPayload(payload: WirePayload): FilePayload | null {
  if (payload.type !== 'file' && payload.type !== 'voice') return null;
  if (typeof payload.file_id !== 'number' || !payload.key || !payload.iv) return null;
  return {
    file_id: payload.file_id,
    file_name: payload.file_name || (payload.type === 'voice' ? 'voice.ogg' : 'файл'),
    mime: payload.mime || 'application/octet-stream',
    size: payload.size ?? 0,
    key: payload.key,
    iv: payload.iv,
    voice: payload.voice,
    duration: payload.duration,
    thumb: payload.thumb,
  };
}

/* ── Приём ───────────────────────────────────────────── */

function ownNames(me: string): Set<string> {
  return new Set([me.trim().toLowerCase()]);
}

async function ingestHistoryMessage(
  api: ChatClient,
  account: AccountKey,
  me: string,
  item: InboxMessage,
): Promise<void> {
  const from = (item.from_username || '').trim().toLowerCase();
  const mine = ownNames(me).has(from);
  const peer = (mine ? item.to_username : from).trim().toLowerCase();

  let text = item.plain_text ?? '';
  if (!text) {
    if (!item.ciphertext) return;
    const pub = await peerPublicKey(api, peer);
    const plain = await decryptDm(account.cryptoKey, pub, item.ciphertext);
    const payload = JSON.parse(plain) as WirePayload;
    text = payload.text ?? '';
  }
  if (!text) return;

  await appendMessage({
    uid: `h${item.id}`,
    sid: item.id,
    peer,
    text,
    mine,
    ts: toUnixSeconds(item.created_at),
    status: mine ? 'delivered' : undefined,
  });
}

/** История шифротекста: очередь pending чистится, история остаётся (как в приложении). */
export async function syncHistory(api: ChatClient, account: AccountKey, me: string): Promise<void> {
  let cursor = (await idbGet<number>(STORE_MESSAGES, keyOf(HISTORY_CURSOR))) ?? 0;
  for (let page = 0; page < 20; page += 1) {
    const result = await api.history(cursor, 500);
    for (const item of result.messages) {
      try {
        await ingestHistoryMessage(api, account, me, item);
      } catch {
        // Чужой или повреждённый конверт не ломает остальную историю.
      }
    }
    cursor = result.next_after_id || cursor;
    await idbPut(STORE_MESSAGES, keyOf(HISTORY_CURSOR), cursor);
    if (!result.has_more) break;
  }
}

/** Легаси-очередь: входящие до ack. */
export async function receivePending(
  api: ChatClient,
  account: AccountKey,
  me = '',
): Promise<{ added: number }> {
  const { messages } = await api.pendingDm();
  let added = 0;
  const ack: number[] = [];

  for (const item of messages) {
    const from = item.from_username.trim().toLowerCase();
    const mine = ownNames(me).has(from);
    const peer = (mine ? item.to_username : from).trim().toLowerCase();
    try {
      let text = item.plain_text ?? '';
      if (!text) {
        if (!item.ciphertext) continue;
        const pub = await peerPublicKey(api, peer);
        const plain = await decryptDm(account.cryptoKey, pub, item.ciphertext);
        const payload = JSON.parse(plain) as WirePayload;
        text = payload.text ?? '';
      }
      if (await appendMessage({
        uid: `l${item.id}`,
        sid: item.id,
        peer,
        text,
        mine,
        ts: toUnixSeconds(item.created_at),
        status: mine ? 'delivered' : undefined,
      })) {
        added += 1;
      }
      ack.push(item.id);
    } catch {
      // Конверт не расшифровался — оставляем на сервере.
    }
  }

  if (ack.length > 0) await api.ackDm(ack);
  return { added };
}

async function resolvePeer(
  api: ChatClient,
  payload: WirePayload,
  keys: V2Keys,
): Promise<string | null> {
  if (payload.peer_hint) return payload.peer_hint.trim().toLowerCase();
  const fromId = payload.from_id;
  if (!fromId) return null;
  if (fromId === identityPubB64(keys)) return null;
  try {
    const found = await api.whois(fromId);
    return found.username.trim().toLowerCase();
  } catch {
    return null;
  }
}

/** Очередь v2: конверты текущего устройства. */
export async function receiveV2(api: ChatClient, keys: V2Keys): Promise<{ added: number }> {
  const { messages } = await api.pendingV2();
  let added = 0;
  const ack: number[] = [];

  for (const item of messages) {
    try {
      const plain = await decryptForMe(keys.device.privateKey, item.envelope);
      const payload = JSON.parse(new TextDecoder().decode(plain)) as WirePayload;
      const file = fileFromPayload(payload);
      const text = typeof payload.text === 'string' ? payload.text : '';
      if (!file && (payload.type !== 'msg' || !text)) {
        ack.push(item.id);
        continue;
      }
      const peer = await resolvePeer(api, payload, keys);
      if (!peer) {
        ack.push(item.id);
        continue;
      }
      if (await appendMessage({
        uid: `v2${item.id}`,
        sid: item.id,
        peer,
        text,
        mine: false,
        ts: toUnixSeconds(item.created_at),
        ...(file ? { file } : {}),
      })) {
        added += 1;
      }
      ack.push(item.id);
    } catch {
      // Не наш конверт или повреждён — не подтверждаем.
    }
  }

  if (ack.length > 0) await api.ack(ack);
  return { added };
}

/* ── Статусы ─────────────────────────────────────────── */

/** Проставляет статус своим сообщениям по id (pending → delivered → read). */
export async function setStatuses(ids: number[], status: MessageStatus): Promise<void> {
  if (ids.length === 0) return;
  const wanted = new Set(ids);
  for (const thread of await listThreads()) {
    const list = await getThread(thread.peer);
    let changed = false;
    for (const message of list) {
      if (message.mine && message.sid > 0 && wanted.has(message.sid) && message.status !== status) {
        message.status = status;
        changed = true;
      }
    }
    if (changed) await idbPut(STORE_MESSAGES, threadKey(thread.peer), list);
  }
}

/** Догоняем статусы после перезагрузки: спрашиваем сервер по своим сообщениям. */
export async function syncStatuses(api: ChatClient): Promise<void> {
  const pending: number[] = [];
  for (const thread of await listThreads()) {
    for (const message of await getThread(thread.peer)) {
      if (message.mine && message.sid > 0 && message.status !== 'read') pending.push(message.sid);
    }
  }
  if (pending.length === 0) return;
  const statuses = await api.deliveryStatus(pending);
  for (const status of ['pending', 'saved', 'delivered', 'read'] as MessageStatus[]) {
    const ids = pending.filter((id) => statuses[String(id)] === status);
    await setStatuses(ids, status);
  }
}

/** Сообщаем серверу, что прочитали сообщения собеседника. */
export async function markPeerRead(api: ChatClient, peer: string): Promise<void> {
  const ids = (await getThread(peer))
    .filter((message) => !message.mine && message.sid > 0)
    .map((message) => message.sid);
  if (ids.length === 0) return;
  try {
    await api.markRead(peer, ids);
  } catch {
    // Отметка чтения не критична для отображения.
  }
}

export function publicKeyBase64(account: AccountKey): string {
  return toBase64(account.publicKey);
}



