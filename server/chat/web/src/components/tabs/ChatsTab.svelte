<script lang="ts">
  import type { ChatPeer, ChatStore } from '../../lib/chat/store.svelte';
  import { dialogTimeLabel } from '../../lib/chat/time';

  interface Props {
    store: ChatStore;
    onopen: (peer: string) => void;
  }

  let { store, onopen }: Props = $props();

  let query = $state('');

  const list = $derived.by(() => {
    const term = query.trim().toLowerCase();
    const peers = store.peers;
    if (!term) return peers;
    return peers.filter(
      (peer) =>
        peer.username.toLowerCase().includes(term) || peer.title.toLowerCase().includes(term),
    );
  });

  function preview(peer: ChatPeer): string {
    if (!peer.preview) return '—';
    return peer.mine ? `Вы: ${peer.preview}` : peer.preview;
  }

  function badge(peer: ChatPeer): number {
    return store.unread[peer.username] ?? 0;
  }
</script>

<div class="tab">
  <div class="search">
    <span class="ci ci-search"></span>
    <input bind:value={query} placeholder="Поиск" aria-label="Поиск по чатам" />
  </div>

  {#if !store.ready}
    <p class="hint">Загрузка чатов…</p>
  {:else if list.length === 0}
    <div class="empty">
      <p class="empty-title">{query ? 'Ничего не найдено' : 'Пока нет чатов'}</p>
      <p class="hint">
        {query ? 'Попробуй другой запрос.' : 'Нажми «+» и найди собеседника по имени.'}
      </p>
    </div>
  {:else}
    <ul class="chats">
      {#each list as peer (peer.username)}
        {@const count = badge(peer)}
        <li>
          <button class="entry" class:unread={count > 0} onclick={() => onopen(peer.username)}>
            <span class="avatar-wrap">
              <span class="avatar">{(peer.title || peer.username).slice(0, 1).toUpperCase()}</span>
              <span class="dot" class:on={!!store.presence[peer.username]}></span>
            </span>

            <span class="main">
              <span class="line">
                <span class="name">{peer.title}</span>
              </span>
              <span class="line">
                <span class="preview">{preview(peer)}</span>
                {#if count > 0}
                  <span class="badge">{count > 99 ? '99+' : count}</span>
                {/if}
              </span>
            </span>

            <span class="side">
              <span class="time">{dialogTimeLabel(peer.ts)}</span>
              {#if peer.mine && peer.preview}
                <span class="tick" class:read={peer.status === 'read'}>
                  {#if peer.status === 'read'}
                    <span class="ci ci-check"></span>
                    <span class="ci ci-check"></span>
                  {:else if peer.status === 'delivered'}
                    <span class="ci ci-check"></span>
                  {:else if peer.status === 'saved'}
                    <span class="ci ci-saved"></span>
                  {:else}
                    <span class="ci ci-clock"></span>
                  {/if}
                </span>
              {/if}
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

  .search {
    display: flex;
    align-items: center;
    gap: 8px;
    margin: 8px 12px;
    padding: 0 10px;
    height: 34px;
    border-radius: 10px;
    background: var(--field);
    color: var(--muted);
    font-size: 16px;
  }

  .search input {
    flex: 1;
    min-width: 0;
    border: 0;
    background: transparent;
    color: var(--text);
    font-size: 14px;
    outline: 0;
  }

  .search input::placeholder {
    color: var(--muted);
  }

  .chats {
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
    transition: background 0.16s ease;
  }

  .entry:hover {
    background: var(--row-hover);
  }

  .entry.unread {
    background: rgba(179, 154, 244, 0.07);
  }

  .avatar-wrap {
    position: relative;
    flex: none;
    width: 52px;
    height: 52px;
    margin-right: 12px;
  }

  .avatar {
    display: grid;
    place-items: center;
    width: 52px;
    height: 52px;
    border-radius: 50%;
    background: var(--row-active);
    color: var(--text);
    font-size: 18px;
    font-weight: 600;
  }

  .dot {
    position: absolute;
    right: -1px;
    bottom: -1px;
    width: 13px;
    height: 13px;
    border: 2px solid var(--bg);
    border-radius: 50%;
    background: rgba(119, 119, 130, 0.35);
  }

  .dot.on {
    background: #6ee7a8;
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
    gap: 6px;
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

  .badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex: none;
    min-height: 22px;
    padding: 0 8px;
    border-radius: 8px;
    background: var(--accent);
    color: #16101f;
    font-size: 11px;
    font-weight: 700;
  }

  .side {
    display: grid;
    justify-items: end;
    gap: 3px;
    flex: none;
    margin-left: 8px;
  }

  .time {
    color: var(--muted);
    font-size: 11px;
    font-variant-numeric: tabular-nums;
  }

  .tick {
    display: inline-flex;
    align-items: center;
    color: var(--muted);
    font-size: 13px;
  }

  .tick .ci + .ci {
    margin-left: -5px;
  }

  .tick.read {
    color: #8fb4ff;
  }

  .hint {
    margin: 0;
    padding: 12px 16px;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
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
