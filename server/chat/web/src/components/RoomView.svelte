<script lang="ts">
  import { onMount, tick } from 'svelte';
  import type { RoomSummary } from '../lib/api/chat';
  import type { ChatStore } from '../lib/chat/store.svelte';
  import type { RoomMessage } from '../lib/chat/rooms';
  import { dayKey, dayLabel, timeLabel } from '../lib/chat/time';

  interface Props {
    store: ChatStore;
    room: RoomSummary;
    onclose: () => void;
  }

  let { store, room, onclose }: Props = $props();

  const POLL_MS = 10_000;

  let messages = $state<RoomMessage[]>([]);
  let draft = $state('');
  let loading = $state(true);
  let sending = $state(false);
  let error = $state('');
  let scroller: HTMLDivElement | undefined = $state();

  const readOnly = $derived(room.room_type === 'channel' && room.role !== 'owner' && room.role !== 'admin');

  onMount(() => {
    let alive = true;

    const load = async (first: boolean) => {
      try {
        const list = await store.openRoom(room);
        if (!alive) return;
        messages = list;
        error = '';
        if (first) await scroll(true);
        else await scroll(false);
      } catch (cause) {
        if (!alive) return;
        error = cause instanceof Error ? cause.message : 'Не удалось открыть комнату';
      } finally {
        if (alive) loading = false;
      }
    };

    void load(true);
    const timer = window.setInterval(() => void load(false), POLL_MS);

    return () => {
      alive = false;
      window.clearInterval(timer);
    };
  });

  async function scroll(force: boolean): Promise<void> {
    await tick();
    if (!scroller) return;
    const near = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 120;
    if (force || near) scroller.scrollTop = scroller.scrollHeight;
  }

  async function send(): Promise<void> {
    const text = draft.trim();
    if (!text || sending || readOnly) return;
    sending = true;
    error = '';
    try {
      await store.sendRoom(room, text);
      draft = '';
      messages = await store.openRoom(room);
      await scroll(true);
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Сообщение не отправлено';
    } finally {
      sending = false;
    }
  }

  function onKeydown(event: KeyboardEvent): void {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      void send();
    }
  }
</script>

<section class="room">
  <header class="appbar">
    <button class="back" aria-label="Назад" onclick={onclose}>
      <span class="ci ci-back"></span>
    </button>
    <span class="avatar">{(room.title || '?').slice(0, 1).toUpperCase()}</span>
    <span class="who">
      <span class="name">{room.title}</span>
      <span class="sub">
        {room.room_type === 'channel' ? 'Канал' : 'Группа'}{#if room.members_count}
          · {room.members_count} участн.{/if}{#if room.username} · @{room.username}{/if}
      </span>
    </span>
  </header>

  <div class="messages" bind:this={scroller}>
    {#if loading}
      <p class="hint center">Загружаем сообщения…</p>
    {:else if messages.length === 0}
      <p class="hint center">Сообщений пока нет.</p>
    {:else}
      {#each messages as message, index (message.uid)}
        {@const prev = index > 0 ? messages[index - 1] : null}
        {@const newDay = !prev || dayKey(prev.ts) !== dayKey(message.ts)}
        {#if newDay}
          <div class="day"><span>{dayLabel(message.ts)}</span></div>
        {/if}
        <div class="row" class:mine={message.mine}>
          {#if !message.mine}
            <span class="from">@{message.from}</span>
          {/if}
          <div class="bubble" class:mine={message.mine}>
            <span class="text">{message.text}</span>
            <time>{timeLabel(message.ts)}</time>
          </div>
        </div>
      {/each}
    {/if}
  </div>

  {#if error}<p class="error">{error}</p>{/if}

  {#if readOnly}
    <p class="hint center">Писать в канале могут только администраторы.</p>
  {:else}
    <form
      class="composer"
      onsubmit={(event) => {
        event.preventDefault();
        void send();
      }}
    >
      <textarea
        class="input"
        bind:value={draft}
        placeholder="Сообщение"
        rows="1"
        onkeydown={onKeydown}
      ></textarea>
      <button class="send" type="submit" disabled={sending || !draft.trim()} aria-label="Отправить">
        {#if sending}
          <span class="spinner"></span>
        {:else}
          <span class="ci ci-send"></span>
        {/if}
      </button>
    </form>
  {/if}
</section>

<style>
  .room {
    display: flex;
    flex: 1 1 auto;
    flex-direction: column;
    width: 100%;
    height: 100%;
    min-height: 0;
    background: var(--bg);
  }

  .appbar {
    display: flex;
    align-items: center;
    gap: 10px;
    flex: none;
    height: 56px;
    padding: 0 10px;
    border-bottom: 1px solid var(--border);
  }

  .back {
    display: grid;
    place-items: center;
    width: 32px;
    height: 32px;
    border: 0;
    border-radius: 50%;
    background: transparent;
    color: var(--text);
    font-size: 18px;
    cursor: pointer;
  }

  .avatar {
    display: grid;
    place-items: center;
    flex: none;
    width: 34px;
    height: 34px;
    border-radius: 50%;
    background: var(--row-active);
    color: var(--text);
    font-size: 14px;
    font-weight: 600;
  }

  .who {
    display: grid;
    min-width: 0;
  }

  .name {
    overflow: hidden;
    font-size: 15px;
    font-weight: 600;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .sub {
    overflow: hidden;
    color: var(--muted);
    font-size: 12px;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .messages {
    flex: 1;
    min-height: 0;
    padding: 10px 12px;
    overflow-y: auto;
  }

  .day {
    display: flex;
    justify-content: center;
    margin: 10px 0 6px;
  }

  .day span {
    padding: 3px 10px;
    border-radius: 10px;
    background: var(--field);
    color: var(--muted);
    font-size: 11px;
  }

  .row {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 2px;
    margin: 4px 0;
  }

  .row.mine {
    align-items: flex-end;
  }

  .from {
    margin-left: 10px;
    color: var(--muted);
    font-size: 11px;
  }

  .bubble {
    display: flex;
    align-items: flex-end;
    gap: 8px;
    max-width: min(560px, 78%);
    padding: 8px 12px;
    border-radius: 16px;
    background: var(--card);
  }

  .bubble.mine {
    background: var(--row-active);
  }

  .text {
    font-size: 14px;
    line-height: 1.4;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }

  .bubble time {
    flex: none;
    color: var(--muted);
    font-size: 10px;
    font-variant-numeric: tabular-nums;
  }

  .composer {
    display: flex;
    align-items: flex-end;
    gap: 8px;
    flex: none;
    padding: 8px 10px calc(8px + env(safe-area-inset-bottom));
    border-top: 1px solid var(--border);
  }

  .input {
    flex: 1;
    min-height: 38px;
    max-height: 140px;
    padding: 9px 12px;
    border: 0;
    border-radius: 18px;
    background: var(--field);
    color: var(--text);
    font: inherit;
    font-size: 14px;
    resize: none;
    outline: 0;
  }

  .send {
    display: grid;
    place-items: center;
    flex: none;
    width: 38px;
    height: 38px;
    border: 0;
    border-radius: 50%;
    background: var(--accent);
    color: #16101f;
    font-size: 20px;
    cursor: pointer;
  }

  .send:disabled {
    opacity: 0.4;
    cursor: default;
  }

  .spinner {
    width: 14px;
    height: 14px;
    border: 2px solid rgba(22, 16, 31, 0.35);
    border-top-color: #16101f;
    border-radius: 50%;
    animation: spin 0.7s linear infinite;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .hint {
    margin: 0;
    padding: 12px 16px;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
  }

  .hint.center {
    text-align: center;
  }

  .error {
    margin: 0 14px 6px;
    color: var(--danger);
    font-size: 13px;
  }
</style>
