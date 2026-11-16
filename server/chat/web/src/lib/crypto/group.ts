import { fromBase64, fromUtf8, toBase64, utf8 } from './bytes';
import { decryptForMe, encryptV2 } from './envelope';

/** Устройство участника: конверт адресуется конкретному ключу, как в приложении. */
export interface GroupDevice {
  device_id: number;
  device_pub: string;
}

/** Конверт комнаты ровно в том виде, который ждёт `/v2/rooms/{type}/{id}/send`. */
export interface GroupEnvelope {
  target_device_id: number;
  target_device_pub: string;
  envelope: string;
}

/** Тело сообщения комнаты: общий JSON, зашифрованный под каждое устройство. */
export function groupPayload(wire: unknown): Uint8Array {
  return utf8(JSON.stringify(wire));
}

/** Шифруем payload под каждое доступное устройство участников. */
export async function sealForDevices(
  devices: GroupDevice[],
  plain: Uint8Array,
): Promise<GroupEnvelope[]> {
  const out: GroupEnvelope[] = [];
  for (const device of devices) {
    if (!device.device_pub || device.device_id <= 0) continue;
    try {
      const envelope = await encryptV2(fromBase64(device.device_pub), plain);
      out.push({
        target_device_id: device.device_id,
        target_device_pub: device.device_pub,
        envelope,
      });
    } catch {
      // Один битый ключ не должен ломать отправку остальным участникам.
    }
  }
  return out;
}

/** Открываем конверт своим устройством; не наш или битый — null. */
export async function openEnvelope(
  devicePrivate: Uint8Array,
  envelope: string,
): Promise<unknown | null> {
  try {
    const plain = await decryptForMe(devicePrivate, envelope);
    return JSON.parse(fromUtf8(plain)) as unknown;
  } catch {
    return null;
  }
}

/** Ключ, по которому комнаты держат отдельную ветку истории. */
export function roomHistoryKey(roomType: string, roomId: number): string {
  return `room:${roomType}:${roomId}`;
}

/** Своё сообщение в комнате храним прямо в base64-конверте своего устройства. */
export function selfEnvelope(devicePub: string, plain: Uint8Array): Promise<string> {
  return encryptV2(fromBase64(devicePub), plain);
}

export function envelopeToBase64(plain: Uint8Array): string {
  return toBase64(plain);
}
