<script lang="ts">
  import { onMount } from 'svelte';
  import type { RoomSummary } from '../../lib/api/chat';
  import type { ChatStore } from '../../lib/chat/store.svelte';
  import { dialogTimeLabel } from '../../lib/chat/time';

  interface Props {
    store: ChatStore;
    onopen: (room: RoomSummary) => void;
  }

  let { store, onopen }: Props = $props();

  let busy = $state(false);
  let error = $state('');
  let creating = $state(false);
  let kind = $state<'group' | 'channel'>('group');
  let username = $state('');
  let title = $state('');
  let saving = $state(false);

  onMount(() => {
    void refresh();
  });

  async function refresh(): Promise<void> {
    busy = true;
    try {
      await store.loadRooms();
      error = '';
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось загрузить группы';
    } finally {
      busy = false;
    }
  }

  async function create(): Promise<void> {
    if (!username.trim() || !title.trim() || saving) return;
    saving = true;
    error = '';
    try {
      const room = await store.createRoom(kind, username, title);
      creating = false;
      username = '';
      title = '';
      onopen(room);
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось создать';
    } finally {
      saving = false;
    }
  }

  function label(room: RoomSummary): string {
    const isChannel = room.room_type === 'channel';
    if (!room.members_count) return isChannel ? 'Канал' : 'Группа';
    const members = room.members_count;
    return `${isChannel ? 'Канал' : 'Группа'} · ${members} ${
      members === 1 ? 'участник' : members < 5 ? 'участника' : 'участников'
    }`;
  }
</script>

<div class="tab">
  {#if creating}
    <div class="create">
      <div class="kinds">
        <button class:active={kind === 'group'} onclick={() => (kind = 'group')}>Группа</button>
        <button class:active={kind === 'channel'} onclick={() => (kind = 'channel')}>Канал</button>
      </div>
      <input bind:value={username} placeholder="@username" aria-label="Адрес" />
      <input bind:value={title} placeholder="Название" aria-label="Название" />
      <div class="create-actions">
        <button class="ghost" onclick={() => (creating = false)}>Отмена</button>
        <button class="primary" disabled={saving || !username.trim() || !title.trim()} onclick={create}>
          {saving ? 'Создаём…' : 'Создать'}
        </button>
      </div>
    </div>
  {:else}
    <div class="head">
      <button class="head-btn" onclick={() => (creating = true)}>
        <span class="ci ci-plus"></span>
        Новая группа или канал
      </button>
    </div>
  {/if}

  {#if error}<p class="error">{error}</p>{/if}

  {#if busy && store.rooms.length === 0}
    <p class="hint">Загружаем группы…</p>
  {:else if store.rooms.length === 0}
    <div class="empty">
      <p class="empty-title">Пока нет групп</p>
      <p class="hint">Создай группу или канал — сообщения в них шифруются на устройстве.</p>
    </div>
  {:else}
    <ul class="rooms">
      {#each store.rooms as room (room.id)}
        <li>
          <button class="entry" onclick={() => onopen(room)}>
            <span class="avatar">{(room.title || room.username || '?').slice(0, 1).toUpperCase()}</span>
            <span class="main">
              <span class="line">
                <span class="name">{room.title}</span>
                {#if room.last_message_at}
                  <span class="time">{dialogTimeLabel(room.last_message_at)}</span>
                {/if}
              </span>
              <span class="line">
                <span class="preview">{room.last_message_text || label(room)}</span>
              </span>
            </span>
          </button>
        </li>
      {/each}
    </ul>
  {/if}
</div>

<style>
  .tab {
    display: flex;
    flex-direction: column;
    min-height: 0;
    height: 100%;
    width: 100%;
    max-width: 760px;
    margin: 0 auto;
  }

  .head {
    display: flex;
    padding: 8px 12px;
  }

  .head-btn {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    height: 36px;
    padding: 0 12px;
    border: 0;
    border-radius: 10px;
    background: var(--field);
    color: var(--text);
    font-size: 14px;
    cursor: pointer;
  }

  .create {
    display: grid;
    gap: 8px;
    padding: 10px 12px;
    border-bottom: 1px solid var(--border);
  }

  .create input {
    height: 36px;
    padding: 0 12px;
    border: 0;
    border-radius: 10px;
    background: var(--field);
    color: var(--text);
    font-size: 14px;
    outline: 0;
  }

  .kinds {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 6px;
  }

  .kinds button {
    height: 32px;
    border: 0;
    border-radius: 10px;
    background: var(--field);
    color: var(--muted);
    font-size: 13px;
    cursor: pointer;
  }

  .kinds button.active {
    background: var(--accent);
    color: #16101f;
    font-weight: 600;
  }

  .create-actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
  }

  .create-actions button {
    height: 32px;
    padding: 0 14px;
    border: 0;
    border-radius: 10px;
    font-size: 13px;
    cursor: pointer;
  }

  .create-actions .ghost {
    background: var(--field);
    color: var(--text);
  }

  .create-actions .primary {
    background: var(--accent);
    color: #16101f;
    font-weight: 600;
  }

  .create-actions .primary:disabled {
    opacity: 0.45;
    cursor: default;
  }

  .rooms {
    flex: 1;
    margin: 0;
    padding: 0 6px 8px;
    list-style: none;
    overflow-y: auto;
  }

  .entry {
    display: flex;
    align-items: center;
    width: 100%;
    margin: 5px 0;
    padding: 10px;
    border: 0;
    border-radius: 20px;
    background: var(--card);
    color: inherit;
    text-align: left;
    cursor: pointer;
  }

  .entry:hover {
    background: var(--row-hover);
  }

  .avatar {
    display: grid;
    place-items: center;
    flex: none;
    width: 48px;
    height: 48px;
    margin-right: 12px;
    border-radius: 50%;
    background: var(--row-active);
    color: var(--text);
    font-size: 17px;
    font-weight: 600;
  }

  .main {
    display: grid;
    gap: 3px;
    min-width: 0;
    flex: 1;
  }

  .line {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
  }

  .name {
    overflow: hidden;
    flex: 1;
    font-size: 15px;
    font-weight: 600;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .preview {
    overflow: hidden;
    flex: 1;
    color: var(--muted);
    font-size: 13px;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .time {
    flex: none;
    color: var(--muted);
    font-size: 11px;
    font-variant-numeric: tabular-nums;
  }

  .hint {
    margin: 0;
    padding: 12px 16px;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
  }

  .error {
    margin: 8px 14px 0;
    color: var(--danger);
    font-size: 13px;
  }

  .empty {
    margin: auto;
    padding: 0 24px 48px;
    text-align: center;
  }

  .empty-title {
    margin: 0 0 4px;
    font-size: 15px;
    font-weight: 600;
  }
</style>
