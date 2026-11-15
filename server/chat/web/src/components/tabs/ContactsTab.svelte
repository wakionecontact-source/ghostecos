<script lang="ts">
  import { searchUsers, type UserHit } from '../../lib/api/me';
  import type { ChatStore } from '../../lib/chat/store.svelte';

  interface Props {
    store: ChatStore;
    token: string;
    onopen: (peer: string) => void;
  }

  let { store, token, onopen }: Props = $props();

  let query = $state('');
  let hits = $state<UserHit[]>([]);
  let searching = $state(false);
  let adding = $state<string | null>(null);
  let error = $state('');
  let timer: number | null = null;

  const contacts = $derived.by(() => {
    const term = query.trim().toLowerCase();
    const list = [...store.contacts].sort((a, b) =>
      (a.display_name || a.username).localeCompare(b.display_name || b.username, 'ru'),
    );
    if (!term) return list;
    return list.filter(
      (item) =>
        item.username.toLowerCase().includes(term) ||
        (item.display_name || '').toLowerCase().includes(term),
    );
  });

  const hitList = $derived(hits.filter((hit) => !isContact(hit.username)));

  function isContact(username: string): boolean {
    return store.contacts.some((item) => item.username === username);
  }

  function onInput() {
    if (timer !== null) window.clearTimeout(timer);
    const term = query.trim();
    if (term.length < 2) {
      hits = [];
      searching = false;
      return;
    }
    searching = true;
    timer = window.setTimeout(async () => {
      try {
        const result = await searchUsers(token, term);
        hits = result.results;
        error = '';
      } catch (cause) {
        error = cause instanceof Error ? cause.message : 'Поиск не удался';
      } finally {
        searching = false;
      }
    }, 300);
  }

  async function add(username: string) {
    adding = username;
    try {
      await store.addContact(username);
      error = '';
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось добавить контакт';
    } finally {
      adding = null;
    }
  }

  let acting = $state<string | null>(null);

  async function remove(username: string) {
    if (!window.confirm(`Удалить @${username} из контактов?`)) return;
    acting = username;
    try {
      await store.removeContact(username);
      error = '';
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось удалить контакт';
    } finally {
      acting = null;
    }
  }

  async function block(username: string) {
    if (!window.confirm(`Заблокировать @${username}? Переписка останется, новые сообщения не придут.`)) {
      return;
    }
    acting = username;
    try {
      await store.block(username);
      error = '';
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось заблокировать';
    } finally {
      acting = null;
    }
  }
</script>

<div class="tab">
  <div class="search">
    <span class="ci ci-search"></span>
    <input bind:value={query} oninput={onInput} placeholder="Имя или @username" aria-label="Поиск людей" />
  </div>

  {#if error}<p class="error">{error}</p>{/if}

  <div class="scroll">
    {#if searching}
      <p class="hint">Ищем…</p>
    {:else if hitList.length > 0}
      <p class="section">Найдены</p>
      <ul class="list">
        {#each hitList as hit (hit.username)}
          <li>
            <div class="row">
              <span class="avatar">{(hit.display_name || hit.username).slice(0, 1).toUpperCase()}</span>
              <span class="body">
                <span class="name">{hit.display_name || hit.username}</span>
                <span class="sub">@{hit.username}{hit.has_keys ? '' : ' · ключей нет'}</span>
              </span>
              <button
                class="mini"
                disabled={adding === hit.username}
                onclick={() => void add(hit.username)}
              >
                {adding === hit.username ? '…' : 'Добавить'}
              </button>
              <button class="mini ghost" onclick={() => onopen(hit.username)}>Написать</button>
            </div>
          </li>
        {/each}
      </ul>
    {/if}

    <p class="section">Контакты</p>
    {#if contacts.length === 0}
      <p class="hint">
        Контактов пока нет. Найди человека по имени или @username выше — чат появится сразу.
      </p>
    {:else}
      <ul class="list">
        {#each contacts as contact (contact.username)}
          <li class="contact-row">
            <button class="row" onclick={() => onopen(contact.username)}>
              <span class="avatar">
                {(contact.display_name || contact.username).slice(0, 1).toUpperCase()}
              </span>
              <span class="body">
                <span class="name">{contact.display_name || contact.username}</span>
                <span class="sub">@{contact.username}</span>
              </span>
            </button>
            <span class="row-actions">
              <button
                class="mini ghost"
                disabled={acting === contact.username}
                onclick={() => void remove(contact.username)}
              >Удалить</button>
              <button
                class="mini ghost danger"
                disabled={acting === contact.username}
                onclick={() => void block(contact.username)}
              >Блок</button>
            </span>
          </li>
        {/each}
      </ul>
    {/if}
  </div>
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

  .scroll {
    flex: 1;
    overflow-y: auto;
    padding-bottom: 8px;
  }

  .section {
    margin: 10px 16px 4px;
    color: var(--muted);
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.04em;
    text-transform: uppercase;
  }

  .list {
    margin: 0;
    padding: 0;
    list-style: none;
  }

  .contact-row {
    display: flex;
    align-items: center;
    gap: 4px;
    padding-right: 10px;
  }

  .contact-row .row {
    flex: 1;
    min-width: 0;
  }

  .row-actions {
    display: flex;
    flex: none;
    gap: 4px;
  }

  .row {
    display: flex;
    align-items: center;
    gap: 12px;
    width: 100%;
    padding: 8px 14px;
    border: 0;
    background: transparent;
    color: inherit;
    text-align: left;
  }

  button.row {
    cursor: pointer;
  }

  button.row:hover {
    background: var(--row-hover);
  }

  .avatar {
    display: grid;
    place-items: center;
    flex: none;
    width: 44px;
    height: 44px;
    border-radius: 50%;
    background: var(--row-active);
    font-size: 16px;
    font-weight: 600;
  }

  .body {
    display: grid;
    gap: 2px;
    min-width: 0;
    flex: 1;
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

  .mini {
    flex: none;
    height: 28px;
    padding: 0 10px;
    border: 0;
    border-radius: 8px;
    background: var(--accent);
    color: #16101f;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
  }

  .mini.ghost {
    background: transparent;
    color: var(--accent);
  }

  .mini:disabled {
    opacity: 0.6;
    cursor: default;
  }

  .hint {
    margin: 0;
    padding: 8px 16px 12px;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
  }

  .error {
    margin: 0 16px 6px;
    color: var(--danger);
    font-size: 13px;
  }
</style>
