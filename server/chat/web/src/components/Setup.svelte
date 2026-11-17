<script lang="ts">
  import { onMount } from 'svelte';
  import type { ChatClient } from '../lib/api/chat';
  import type { AccountKey } from '../lib/crypto/account-key';
  import type { V2Keys } from '../lib/chat/keys';
  import { prepareAccount, type SetupStep } from '../lib/chat/setup';

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

  let busy = $state(true);
  let step = $state<SetupStep | null>(null);
  let error = $state('');

  onMount(() => {
    void run();
  });

  async function run() {
    busy = true;
    error = '';
    try {
      const result = await prepareAccount(api, username, (value) => {
        step = value;
      });
      onready(result.account, result.v2);
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось подготовить ключи';
      busy = false;
    }
  }

  const label = $derived(step ? STEPS[step] : 'Готовим ключи');
</script>

<main class="screen">
  <div class="pane">
    <h1>{username}</h1>

    {#if error}
      <p class="muted">Ключи не готовы.</p>
      <p class="error">{error}</p>
      <button class="button primary" onclick={run} disabled={busy}>Повторить</button>
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

  .muted,
  .fine {
    margin: 0;
    color: var(--muted);
    font-size: 13px;
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
