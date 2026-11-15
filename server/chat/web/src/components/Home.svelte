<script lang="ts">
  import { onMount, untrack } from 'svelte';
  import ChatView from './ChatView.svelte';
  import ChatsTab from './tabs/ChatsTab.svelte';
  import ContactsTab from './tabs/ContactsTab.svelte';
  import ProfileTab from './tabs/ProfileTab.svelte';
  import SettingsTab from './tabs/SettingsTab.svelte';
  import { fetchMe, type MeProfile } from '../lib/api/me';
  import type { WebSession } from '../lib/auth/session';
  import { ChatStore } from '../lib/chat/store.svelte';
  import type { V2Keys } from '../lib/chat/keys';
  import type { AccountKey } from '../lib/crypto/account-key';

  interface Props {
    session: WebSession;
    account: AccountKey;
    v2: V2Keys | null;
    onlogout: () => void;
  }

  let { session, account, v2, onlogout }: Props = $props();

  type Tab = 'chats' | 'contacts' | 'profile' | 'settings';

  let tab = $state<Tab>('chats');
  let peer = $state<string | null>(null);
  let picker = $state(false);
  let me = $state<MeProfile | null>(null);
  let meError = $state('');

  // Сессия и ключ живут весь срок экрана: читаем их один раз.
  const store = new ChatStore(
    untrack(() => session.token),
    untrack(() => account),
    untrack(() => v2),
    untrack(() => session.username),
  );

  const titles: Record<Tab, string> = {
    chats: 'GhostChat',
    contacts: 'Контакты',
    profile: 'Профиль',
    settings: 'Настройки',
  };

  onMount(() => {
    const stop = store.start();
    void loadMe();
    return stop;
  });

  async function loadMe(): Promise<void> {
    try {
      me = await fetchMe(session.token);
      meError = '';
    } catch (cause) {
      meError = cause instanceof Error ? cause.message : 'Профиль недоступен';
    }
  }

  function open(peerName: string) {
    peer = peerName;
    picker = false;
  }
</script>

<div class="shell">
  <header class="appbar">
    <span class="brand">
      {#if tab === 'chats'}Ghost<em>Chat</em>{:else}{titles[tab]}{/if}
    </span>
    {#if store.online}
      <span class="live" title="Соединение активно"></span>
    {/if}
    <div class="bar-right">
      {#if tab === 'chats'}
        <button class="icon-btn" aria-label="Новый чат" onclick={() => (picker = true)}>
          <span class="ci ci-plus"></span>
        </button>
      {/if}
    </div>
  </header>

  <main class="content">
    {#if tab === 'chats'}
      <div class="split">
        <div class="listcol">
          <ChatsTab {store} onopen={open} />
        </div>
        <div class="threadpane">
          {#if peer}
            {#key peer}
              <ChatView
                {store}
                peer={peer}
                title={store.titleOf(peer)}
                onclose={() => (peer = null)}
              />
            {/key}
          {:else}
            <div class="pane-empty">
              <p class="pane-title">Выбери чат</p>
              <p class="pane-hint">Сообщения шифруются на устройстве — ключ не покидает браузер.</p>
            </div>
          {/if}
        </div>
      </div>
    {:else if tab === 'contacts'}
      <ContactsTab {store} token={session.token} onopen={open} />
    {:else if tab === 'profile'}
      <ProfileTab
        {session}
        {me}
        error={meError}
        onrefresh={loadMe}
        onsettings={() => (tab = 'settings')}
        onlogout={onlogout}
      />
    {:else}
      <SettingsTab {session} {me} onlogout={onlogout} />
    {/if}
  </main>

  <nav class="tabbar">
    <button class:active={tab === 'chats'} onclick={() => (tab = 'chats')}>
      <span class="ci ci-chat"></span>
      <span>Чаты</span>
    </button>
    <button class:active={tab === 'contacts'} onclick={() => (tab = 'contacts')}>
      <span class="ci ci-people"></span>
      <span>Контакты</span>
    </button>
    <button class:active={tab === 'profile'} onclick={() => (tab = 'profile')}>
      <span class="ci ci-person"></span>
      <span>Профиль</span>
    </button>
    <button class:active={tab === 'settings'} onclick={() => (tab = 'settings')}>
      <span class="ci ci-gear"></span>
      <span>Настройки</span>
    </button>
  </nav>

  {#if peer}
    <div class="overlay thread">
      {#key peer}
        <ChatView
          {store}
          peer={peer}
          title={store.titleOf(peer)}
          onclose={() => (peer = null)}
        />
      {/key}
    </div>
  {/if}

  {#if picker}
    <div class="overlay picker">
      <header class="appbar">
        <button class="icon-btn" aria-label="Закрыть" onclick={() => (picker = false)}>‹</button>
        <span class="overlay-title">Новый чат</span>
      </header>
      <div class="overlay-body">
        <ContactsTab {store} token={session.token} onopen={open} />
      </div>
    </div>
  {/if}
</div>

<style>
  .shell {
    position: relative;
    display: flex;
    flex-direction: column;
    height: 100%;
    width: 100%;
    background: var(--bg);
    overflow: hidden;
  }

  .appbar {
    display: flex;
    align-items: center;
    gap: 8px;
    height: 52px;
    padding: 0 8px 0 16px;
    border-bottom: 1px solid var(--border);
    background: var(--header-blur);
    backdrop-filter: blur(18px) saturate(1.4);
    -webkit-backdrop-filter: blur(18px) saturate(1.4);
  }

  .brand {
    display: inline-flex;
    align-items: baseline;
    font-size: 17px;
    font-weight: 700;
    letter-spacing: -0.02em;
    white-space: nowrap;
  }

  .brand em {
    color: var(--accent);
    font-style: normal;
  }

  .live {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: #6ee7a8;
  }

  .bar-right {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-left: auto;
  }

  .icon-btn {
    display: grid;
    place-items: center;
    width: 36px;
    height: 36px;
    border: 0;
    border-radius: 50%;
    background: transparent;
    color: var(--text);
    font-size: 24px;
    line-height: 1;
    cursor: pointer;
  }

  .icon-btn:hover {
    background: var(--row-hover);
  }

  .overlay-title {
    font-size: 15px;
    font-weight: 600;
  }

  .content {
    flex: 1;
    min-height: 0;
    display: flex;
  }

  .split {
    display: flex;
    width: 100%;
    height: 100%;
    min-height: 0;
  }

  .listcol {
    display: flex;
    flex: 1;
    min-width: 0;
  }

  .threadpane {
    display: none;
    min-width: 0;
  }

  .pane-empty {
    display: grid;
    align-content: center;
    justify-items: center;
    gap: 6px;
    width: 100%;
    padding: 24px;
    text-align: center;
  }

  .pane-title {
    margin: 0;
    font-size: 16px;
    font-weight: 600;
  }

  .pane-hint {
    margin: 0;
    max-width: 34ch;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
  }

  .tabbar {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    border-top: 1px solid var(--border);
    background: var(--header-blur);
    backdrop-filter: blur(18px) saturate(1.4);
    -webkit-backdrop-filter: blur(18px) saturate(1.4);
    padding-bottom: env(safe-area-inset-bottom);
  }

  .tabbar button {
    display: grid;
    justify-items: center;
    gap: 3px;
    padding: 9px 0 8px;
    border: 0;
    background: transparent;
    color: var(--muted);
    font-size: 10px;
    cursor: pointer;
  }

  .tabbar button.active {
    color: var(--accent);
  }

  .tabbar button .ci {
    font-size: 22px;
  }

  .overlay {
    position: absolute;
    inset: 0;
    z-index: 20;
    display: flex;
    flex-direction: column;
    background: var(--bg);
    animation: slideIn 0.22s cubic-bezier(0.25, 0.46, 0.45, 0.94) both;
  }

  .overlay-body {
    flex: 1;
    min-height: 0;
  }

  @keyframes slideIn {
    from {
      transform: translateX(12px);
      opacity: 0.4;
    }
    to {
      transform: none;
      opacity: 1;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .overlay {
      animation: none;
    }
  }

  /* Широкий экран: навигация слева, список чатов и переписка рядом. */
  @media (min-width: 900px) {
    .shell {
      display: grid;
      grid-template-columns: 88px minmax(0, 1fr);
      grid-template-rows: 56px minmax(0, 1fr);
    }

    .appbar {
      grid-column: 2;
      grid-row: 1;
    }

    .content {
      grid-column: 2;
      grid-row: 2;
    }

    .tabbar {
      grid-column: 1;
      grid-row: 1 / span 2;
      display: flex;
      flex-direction: column;
      gap: 4px;
      padding: 10px 6px;
      border-top: 0;
      border-right: 1px solid var(--border);
    }

    .tabbar button {
      gap: 5px;
      padding: 12px 0;
      border-radius: 12px;
    }

    .tabbar button.active {
      background: var(--row-active);
    }

    .split {
      display: grid;
      grid-template-columns: 340px minmax(0, 1fr);
    }

    .threadpane {
      display: flex;
      border-left: 1px solid var(--border);
    }

    .overlay.thread {
      display: none;
    }
  }
</style>

