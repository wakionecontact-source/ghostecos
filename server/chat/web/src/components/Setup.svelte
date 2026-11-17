<script lang="ts">
  import { onMount } from 'svelte';
  import type { ChatClient } from '../lib/api/chat';
  import type { AccountKey } from '../lib/crypto/account-key';
  import type { V2Keys } from '../lib/chat/keys';
  import { checkAccount, prepareAccount, type AccountState, type SetupStep } from '../lib/chat/setup';

  interface Props {
    api: ChatClient;
    username: string;
    onready: (account: AccountKey, v2: V2Keys | null) => void;
    onlogout: () => void;
  }

  let { api, username, onready, onlogout }: Props = $props();

  const STEPS: Record<SetupStep, string> = {
    account: 'Создаём ключ аккаунта',
    identity: 'Создаём ключ переписки',
    device: 'Проверяем это устройство',
  };

  let mode = $state<AccountState | 'loading'>('loading');
  let step = $state<SetupStep | null>(null);
  let password = $state('');
  let busy = $state(false);
  let error = $state('');

  onMount(() => {
    void start();
  });

  /** Быстрый путь: сейф браузера или новый ключ — без вопросов. */
  async function start() {
    busy = true;
    error = '';
    try {
      mode = await checkAccount(api);
      if (mode === 'password') {
        busy = false;
        return;
      }
      await prepare('');
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Нет связи с сервером';
      busy = false;
    }
  }

  async function prepare(secret: string) {
    busy = true;
    error = '';
    try {
      const result = await prepareAccount(api, username, (value) => {
        step = value;
      }, secret);
      onready(result.account, result.v2);
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось подготовить ключи';
      busy = false;
    }
  }

  function submit(event: SubmitEvent) {
    event.preventDefault();
    if (!password || busy) return;
    void prepare(password);
  }

  /** Новый ключ вместо утраченного: старые сообщения станут нечитаемыми. */
  function createInstead() {
    password = '';
    mode = 'new';
    void prepare('');
  }

  const label = $derived(step ? STEPS[step] : 'Готовим ключи');
</script>

<main class="screen">
  <div class="pane">
    <h1>{username}</h1>

    {#if error}
      <p class="error">{error}</p>
      <button class="button primary" onclick={start} disabled={busy}>Повторить</button>
    {:else if mode === 'password'}
      <p class="muted">
        На этом устройстве ключа нет, но копия есть на сервере. Введи пароль аккаунта — им
        открывается только копия, сам пароль не сохраняется.
      </p>
      <form onsubmit={submit}>
        <label class="field-label" for="password">Пароль аккаунта</label>
        <input
          id="password"
          class="field"
          type="password"
          autocomplete="current-password"
          bind:value={password}
        />
        <button class="button primary" type="submit" disabled={busy || !password}>
          {busy ? 'Открываем…' : 'Открыть'}
        </button>
      </form>
      <button class="link" onclick={createInstead} disabled={busy}>
        Создать новый ключ на этом устройстве
      </button>
    {:else}
      <p class="muted">{label}…</p>
      <p class="fine">Ключи хранятся в защищённом хранилище этого браузера и никуда не уходят.</p>
    {/if}

    <button class="link" onclick={onlogout}>Выйти</button>
  </div>
</main>

<style>
  .screen {
    display: grid;
    place-items: center;
    min-height: 100%;
    padding: 24px 16px;
  }

  .pane {
    display: grid;
    gap: 12px;
    width: min(100%, 360px);
    padding: 24px;
    border: 1px solid var(--border);
    border-radius: 18px;
    background: var(--card);
  }

  h1 {
    margin: 0 0 4px;
    font-size: 18px;
    font-weight: 600;
    letter-spacing: -0.01em;
  }

  form {
    display: grid;
    gap: 10px;
  }

  .field-label,
  .muted {
    color: var(--muted);
    font-size: 13px;
  }

  .muted,
  .fine {
    margin: 0;
  }

  .fine {
    color: var(--muted);
    font-size: 12px;
  }

  .error {
    margin: 0;
    color: var(--danger, #f87171);
    font-size: 13px;
  }

  .link {
    justify-self: start;
    padding: 0;
    border: 0;
    background: none;
    color: var(--muted);
    font-size: 13px;
    cursor: pointer;
  }
</style>
