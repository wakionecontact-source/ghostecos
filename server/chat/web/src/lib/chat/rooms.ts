import type { ChatClient, RoomMember, RoomMessageRow, RoomSummary } from '../api/chat';
import { fromBase64, utf8 } from '../crypto/bytes';
import { groupPayload, openEnvelope, sealForDevices, type GroupDevice } from '../crypto/group';
import { v2FromDevice, type V2Keys } from './keys';
import { toUnixSeconds } from './time';

/** Сообщение комнаты после расшифровки — минимальный набор для ленты. */
export interface RoomMessage {
  uid: string;
  id: number;
  from: string;
  mine: boolean;
  text: string;
  ts: number;
}

const KEYS_TTL = 60_000;
const deviceCache = new Map<string, { devices: GroupDevice[]; at: number }>();

async function peerDevices(api: ChatClient, username: string, force = false): Promise<GroupDevice[]> {
  const key = username.trim().toLowerCase();
  const hit = deviceCache.get(key);
  if (!force && hit && Date.now() - hit.at < KEYS_TTL) return hit.devices;
  try {
    const bundle = await api.peerKeys(username);
    const devices = bundle.devices
      .filter((device) => device.device_pub && device.device_id > 0)
      .map((device) => ({ device_id: device.device_id, device_pub: device.device_pub }));
    deviceCache.set(key, { devices, at: Date.now() });
    return devices;
  } catch {
    return [];
  }
}

/** Мои комнаты: группы и каналы одним списком, как в приложении. */
export async function listRooms(api: ChatClient): Promise<RoomSummary[]> {
  const { rooms } = await api.roomsMy();
  return rooms ?? [];
}

/** Читаем ленту комнаты и расшифровываем конверты текущим устройством. */
export async function loadRoom(
  api: ChatClient,
  keys: V2Keys | null,
  room: RoomSummary,
  username: string,
): Promise<RoomMessage[]> {
  const { messages } = await api.roomMessages(room.room_type, room.id);
  const mine = username.trim().toLowerCase();
  const out: RoomMessage[] = [];

  for (const row of messages ?? []) {
    const message = await openRow(row, keys, mine);
    if (message) out.push(message);
  }
  return out;
}

async function openRow(
  row: RoomMessageRow,
  keys: V2Keys | null,
  myUsername: string,
): Promise<RoomMessage | null> {
  const from = (row.sender_username ?? '').trim().toLowerCase();
  const ts = toUnixSeconds(row.created_at ?? 0);
  const mine = !!myUsername && from === myUsername;

  let text = '';
  if (typeof row.payload === 'string' && row.payload) {
    // Открытые каналы идут без E2E: payload уже читаемый.
    text = readText(row.payload);
  } else if (row.envelope && keys) {
    const wire = await openEnvelope(keys.device.privateKey, row.envelope);
    text = readWire(wire);
  }

  if (!text) return null;
  return { uid: `r${row.id}`, id: row.id, from, mine, text, ts };
}

function readText(payload: string): string {
  try {
    const parsed = JSON.parse(payload) as unknown;
    return readWire(parsed);
  } catch {
    return payload;
  }
}

function readWire(wire: unknown): string {
  if (typeof wire === 'string') return wire;
  if (!wire || typeof wire !== 'object') return '';
  const value = wire as Record<string, unknown>;
  if (typeof value.text === 'string') return value.text;
  return '';
}

/** Отправка: по конверту на каждое устройство всех участников плюс своё. */
export async function sendRoomMessage(
  api: ChatClient,
  keys: V2Keys | null,
  room: RoomSummary,
  username: string,
  text: string,
): Promise<void> {
  const trimmed = text.trim();
  if (!trimmed) throw new Error('Пустое сообщение');
  if (!keys) throw new Error('Нет ключа устройства — войди с паролем');

  const members = await api.roomMembers(room.room_type, room.id);
  const usernames = new Set<string>([username.trim().toLowerCase()]);
  for (const member of members.members ?? []) {
    const name = (member.username ?? '').trim().toLowerCase();
    if (name) usernames.add(name);
  }

  const wire = {
    v: 2,
    type: 'msg',
    text: trimmed,
    ts: Math.floor(Date.now() / 1000),
    sid: Date.now() * 1000 + Math.floor(Math.random() * 1000),
  };
  const plain = groupPayload(wire);

  const devices: GroupDevice[] = [];
  for (const name of usernames) {
    devices.push(...(await peerDevices(api, name)));
  }
  if (devices.length === 0) throw new Error('У участников нет доступных ключей устройств');

  const envelopes = await sealForDevices(devices, plain);
  if (envelopes.length === 0) throw new Error('Не удалось зашифровать для участников');

  await api.roomSend(room.room_type, room.id, {
    envelopes,
    client_message_id: `web-${wire.sid}`,
  });
}

/** Участники для шапки комнаты. */
export async function roomMembers(api: ChatClient, room: RoomSummary): Promise<RoomMember[]> {
  const { members } = await api.roomMembers(room.room_type, room.id);
  return members ?? [];
}

/** Свои ключи нужны, чтобы читать конверты после перезагрузки страницы. */
export async function roomKeys(current: V2Keys | null): Promise<V2Keys | null> {
  if (current) return current;
  return v2FromDevice().catch(() => null);
}

export { fromBase64, utf8 };
