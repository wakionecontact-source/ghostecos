import { requestJson } from './http';

export interface Capabilities {
  protocol: number;
  signed_messages: boolean;
  idempotent_dm: boolean;
  idempotent_rooms: boolean;
  idempotent_files: boolean;
  max_file_bytes: number;
  max_envelope_chars: number;
  websocket: string;
  file_retention_days: number;
  public_rooms_encrypted: boolean;
  bots_encrypted: boolean;
}

export interface IdentityMe {
  identity_pub: string | null;
  identity_priv_encrypted: string | null;
  identity_salt: string | null;
}

export interface PeerDevice {
  device_id: number;
  device_pub: string;
  signed_prekey_sig: string;
}

export interface PeerKeys {
  username: string;
  identity_pub: string | null;
  devices: PeerDevice[];
}

export interface DeviceEnvelope {
  target_device_id: number;
  target_device_pub?: string;
  envelope: string;
}

export interface PendingEnvelope {
  id: number;
  envelope: string;
  created_at: number;
  sender_username?: string;
  sender_identity_pub?: string;
  signature?: string;
  target_device_id?: number;
}

export interface Contact {
  username: string;
  display_name: string;
  added_at?: number;
}

/** Серверная копия E2E-ключа — тот же контракт, что в приложении. */
export interface MyKeys {
  x25519_pub: string | null;
  encrypted_private_key: string | null;
  key_salt: string | null;
  key_kdf?: string | null;
  key_format?: string | null;
}

export interface PeerKeysLegacy {
  username: string;
  x25519_pub: string | null;
}

export interface InboxMessage {
  id: number;
  from_username: string;
  from_display_name?: string;
  to_username: string;
  ciphertext?: string | null;
  plain_text?: string | null;
  created_at: number | string;
}

export interface V2EnvelopeItem {
  id: number;
  envelope: string;
  created_at: number | string;
}

export interface V2SendBody {
  to_username: string;
  envelopes: { target_device_id: number; envelope: string }[];
}

export interface PrivacyFlags {
  show_online?: boolean;
  send_read_receipts?: boolean;
  allow_channel_add?: boolean;
  allow_group_add?: boolean;
  message_privacy?: string;
  username_visibility?: string;
  display_name_visibility?: string;
  avatar_visibility?: string;
  banner_visibility?: string;
  about_visibility?: string;
  music_visibility?: string;
  created_visibility?: string;
}

export interface DeviceRow {
  id: number;
  device_id: string;
  device_name: string | null;
  platform: string | null;
  is_owner: boolean | number;
  level?: number;
  is_active: boolean | number;
  is_blocked: boolean | number;
  last_seen: number | null;
  created_at?: number | null;
  expires_at?: number | null;
  is_current?: boolean;
}

export interface ChatApi {
  token: string;
}

function withToken(token: string): { token: string } {
  return { token };
}

export function chatApi(token: string) {
  const opts = withToken(token);
  return {
    capabilities: () => requestJson<Capabilities>('/api/chat/v2/client/capabilities', opts),

    myIdentity: () => requestJson<IdentityMe>('/api/chat/v2/identity/me', opts),

    publishIdentity: (body: {
      identity_pub: string;
      proof_signature: string;
      identity_priv_encrypted?: string;
      identity_salt?: string;
      identity_kdf?: string;
    }) => requestJson<{ status: string }>('/api/chat/v2/identity/publish', { ...opts, body }),

    publishDevice: (body: {
      device_pub: string;
      signed_prekey_sig: string;
      replace?: boolean;
    }) =>
      requestJson<{ status: string; device_id: number }>('/api/chat/v2/device/publish', {
        ...opts,
        body,
      }),

    peerKeys: (username: string) =>
      requestJson<PeerKeys>(`/api/chat/v2/keys/${encodeURIComponent(username)}`, opts),

    whois: (identityPub: string) =>
      requestJson<{ username: string; display_name: string }>(
        `/api/chat/v2/whois?identity_pub=${encodeURIComponent(identityPub)}`,
        opts,
      ),

    send: (body: {
      client_message_id?: string;
      sender_identity_pub?: string;
      to_username: string;
      envelopes: DeviceEnvelope[];
    }) =>
      requestJson<{ status: string; delivered_to_devices: number; ids: number[] }>('/api/chat/v2/send', {
        ...opts,
        body,
      }),

    pending: () => requestJson<{ messages: PendingEnvelope[] }>('/api/chat/v2/pending', opts),

    ack: (ids: number[]) =>
      requestJson<{ status: string; deleted: number }>('/api/chat/v2/ack', { ...opts, body: { ids } }),

    /** Отправка v2: по конверту на каждое устройство получателя. */
    sendV2: (body: V2SendBody) =>
      requestJson<{ status: string; delivered_to_devices: number; ids: number[] }>(
        '/api/chat/v2/send',
        { ...opts, body },
      ),

    pendingV2: () =>
      requestJson<{ messages: V2EnvelopeItem[] }>('/api/chat/v2/pending', opts),

    /** История шифротекста: очередь pending чистится, история остаётся. */
    history: (afterId = 0, limit = 500) =>
      requestJson<{ messages: InboxMessage[]; next_after_id: number; has_more: boolean }>(
        `/api/chat/history?after_id=${afterId}&limit=${limit}`,
        opts,
      ),

    contacts: () => requestJson<Contact[]>('/api/chat/contacts', opts),

    /* ── Личные сообщения приложения (P-256, /api/chat/*) ── */

    myKeys: () => requestJson<MyKeys>('/api/chat/keys/me', opts),

    /** Публикация ключа — сервер сам различает v1 (65 байт) и v2 (32 байта). */
    uploadKeys: (body: {
      x25519_pub: string;
      encrypted_private_key?: string;
      key_salt?: string;
      key_kdf?: string;
      key_format?: string;
      storage_mode: 'server' | 'local';
      signed_prekey_sig?: string;
      replace?: boolean;
    }) =>
      requestJson<{ status: string; key_type?: string; device_id?: number }>(
        '/api/chat/keys/upload',
        { ...opts, body },
      ),

    peerPub: (username: string) =>
      requestJson<PeerKeysLegacy>(`/api/chat/keys/${encodeURIComponent(username)}`, opts),

    sendDm: (body: { to_username: string; ciphertext: string }) =>
      requestJson<{ status: string; id: number; created_at: number | string; recipient_online: boolean }>(
        '/api/chat/send',
        { ...opts, body },
      ),

    pendingDm: () => requestJson<{ messages: InboxMessage[] }>('/api/chat/pending', opts),

    ackDm: (ids: number[]) =>
      requestJson<{ status: string; acked: number }>('/api/chat/ack', { ...opts, body: { ids } }),

    /** Отметка «прочитано» — сервер пересылает sender'у chat.read. */
    markRead: (fromUsername: string, ids: number[]) =>
      requestJson<{ sent: number }>('/api/chat/read', {
        ...opts,
        body: { from_username: fromUsername, ids },
      }),

    /** Статусы своих сообщений: pending → delivered → read. */
    deliveryStatus: (ids: number[]) =>
      requestJson<Record<string, 'pending' | 'delivered' | 'read'>>('/api/chat/delivery_status', {
        ...opts,
        body: { ids },
      }),

    addContact: (username: string) =>
      requestJson<{ status: string; username: string; display_name: string }>(
        `/api/chat/contacts/${encodeURIComponent(username)}`,
        { ...opts, method: 'POST', body: {} },
      ),

    unread: () => requestJson<{ count: number }>('/api/chat/unread', opts),

    /* ── Настройки: приватность и устройства ── */

    privacy: () => requestJson<PrivacyFlags>('/api/chat/privacy', opts),

    setPrivacy: (flags: PrivacyFlags) =>
      requestJson<PrivacyFlags>('/api/chat/privacy', { ...opts, body: flags }),

    devices: () =>
      requestJson<{ devices: DeviceRow[]; current_id: number | null }>('/api/chat/devices', opts),

    renameDevice: (devicePk: number, name: string) =>
      requestJson<{ status: string; name: string }>(
        `/api/chat/devices/${devicePk}/rename`,
        { ...opts, body: { name } },
      ),

    revokeDevice: (devicePk: number) =>
      requestJson<{ status: string }>(`/api/chat/devices/${devicePk}/revoke`, {
        ...opts,
        body: {},
      }),

    /* ── Контакты и блокировки ── */

    removeContact: (username: string) =>
      requestJson<{ status: string }>(`/api/chat/contacts/${encodeURIComponent(username)}`, {
        ...opts,
        method: 'DELETE',
      }),

    block: (username: string) =>
      requestJson<{ status: string; username: string }>(
        `/api/chat/block/${encodeURIComponent(username)}`,
        { ...opts, body: {} },
      ),

    unblock: (username: string) =>
      requestJson<{ status: string; username: string }>(
        `/api/chat/block/${encodeURIComponent(username)}`,
        { ...opts, method: 'DELETE' },
      ),

    clearChatWith: (username: string, both = false) =>
      requestJson<{ status: string }>(
        `/api/chat/chat/with/${encodeURIComponent(username)}?both=${both ? 'true' : 'false'}`,
        { ...opts, method: 'DELETE' },
      ),

    /* ── Зашифрованные файлы ── */

    /** Blob уже зашифрован на клиенте: сервер видит только ciphertext. */
    uploadFile: (toUsername: string, blob: Uint8Array) => {
      const form = new FormData();
      form.append('to_username', toUsername);
      const copy = new Uint8Array(blob.length);
      copy.set(blob);
      form.append(
        'blob',
        new Blob([copy.buffer as ArrayBuffer], { type: 'application/octet-stream' }),
        'blob.bin',
      );
      return requestJson<{ file_id: number; size: number }>('/api/chat/file/upload', {
        ...opts,
        form,
      });
    },

    /** Скачивание ciphertext вложения — без разбора JSON. */
    downloadFile: async (fileId: number): Promise<Uint8Array> => {
      const response = await fetch(`/api/chat/file/${fileId}`, {
        headers: { Authorization: `Bearer ${token}` },
        credentials: 'same-origin',
      });
      if (!response.ok) throw new Error(`Файл недоступен (${response.status})`);
      return new Uint8Array(await response.arrayBuffer());
    },

    ackFile: (fileId: number) =>
      requestJson<{ deleted: number }>(`/api/chat/file/${fileId}/ack`, { ...opts, body: {} }),
  };
}

export type ChatClient = ReturnType<typeof chatApi>;

