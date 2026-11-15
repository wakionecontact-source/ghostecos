<script lang="ts">
  import { onMount } from 'svelte';
  import type { ChatClient, IdentityMe, MyKeys } from '../lib/api/chat';
  import { unlockAccount } from '../lib/auth/account';
  import { saveDeviceVault } from '../lib/auth/vault';
  import {
    activateV2Pair,
    checkV2Pair,
    ReplaceRequiredError,
    type V2Keys,
    type V2PairCheck,
  } from '../lib/chat/keys';
  import { generateKeys, publishAccountKey } from '../lib/chat/provision';
  import type { AccountKey } from '../lib/crypto/account-key';

  interface Props {
    api: ChatClient;
    username: string;
    onready: (account: AccountKey, v2: V2Keys | null) => void;
    onlogout: () => void;
  }

  let { api, username, onready, onlogout }: Props = $props();

  let keys = $state<MyKeys | null>(null);
  let identity = $state<IdentityMe | null>(null);
  let password = $state('');
  let busy = $state(false);
  let error = $state('');
  let askReplace = $state(false);
  let account = $state<AccountKey | null>(null);
  let decision = $state<V2PairCheck | null>(null);

  const canUnlock = $derived(!!keys?.encrypted_private_key && !!keys?.key_salt);
  const hasIdentity = $derived(!!identity?.identity_pub);
  const needCreate = $derived(!hasIdentity && !canUnlock);

  onMount(async () => {
    try {
      const [keyState, identityState] = await Promise.all([
        api.myKeys(),
        api.myIdentity().catch(() => null),
      ]);
      keys = keyState;
      identity = identityState;
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Нет связи с сервером';
    }
  });

  function fail(cause: unknown) {
    if (cause instanceof ReplaceRequiredError) askReplace = true;
    error = cause instanceof Error ? cause.message : 'Не удалось открыть ключ';
  }

  function finish(v2: V2Keys | null) {
    if (!account) return;
    onready(account, v2);
  }

  /** Ключ v2 готов или его надо создать — решает checkV2Pair. */
  function handleCheck(check: V2PairCheck) {
    if (check.state === 'ready') {
      finish(check.keys);
      return;
    }
    decision = check;
  }

  async function open() {
    busy = true;
    error = '';
    try {
      account = await unlockAccount(api, password, username);
      const check = await checkV2Pair(api, { username, password });
      handleCheck(check);
    } catch (cause) {
      fail(cause);
    } finally {
      busy = false;
    }
  }

  /** Новый аккаунт: ключ v1 в серверную копию, пара v2 — после ответа о копии. */
  async function create() {
    busy = true;
    error = '';
    try {
      const generated = await generateKeys();
      await publishAccountKey(api, username, generated.account, 'server', password, askReplace);
      await saveDeviceVault({
        accountPkcs8: generated.account.pkcs8,
        accountPublic: generated.account.publicKey,
      });
      account = generated.account;
      decision = { state: 'created', keys: generated.v2, hasServerBackup: false, serverIdentity: null };
    } catch (cause) {
      fail(cause);
    } finally {
      busy = false;
    }
  }

  /** Отправляем ли зашифрованную копию identity на сервер — отдельный выбор. */
  async function publishV2(uploadCopy: boolean) {
    if (!decision) return;
    busy = true;
    error = '';
    try {
      const { keys: v2, state } = decision;
      await activateV2Pair(api, {
        username,
        keys: v2,
        uploadCopy,
        password,
        rotate: state === 'locked',
      });
      decision = null;
      finish(v2);
    } catch (cause) {
      fail(cause);
    } finally {
      busy = false;
    }
  }

  function submit(event: SubmitEvent) {
    event.preventDefault();
    if (!password || busy || decision) return;
    void (canUnlock ? open() : create());
  }
</script>

<main class="screen">
  <div class="pane">
    <h1>{username}</h1>

    {#if !keys}
      <p class="muted">Проверяем ключи…</p>
    {:else if decision?.state === 'created'}
      <p class="muted">Ключ v2 создан на этом устройстве.</p>
      <button class="button primary" onclick={() => publishV2(true)} disabled={busy}>
        Отправить копию на сервер
      </button>
      <button class="button" onclick={() => publishV2(false)} disabled={busy}>
        Только на устройстве
      </button>
    {:else if decision?.state === 'locked'}
      <p class="muted">Копии ключа v2 на сервере нет.</p>
      <button class="button primary" onclick={() => publishV2(true)} disabled={busy}>
        Создать новый ключ v2
      </button>
      <p class="muted">Прежние сообщения v2 останутся нечитаемыми.</p>
    {:else}
      <form onsubmit={submit}>
        <label class="field-label" for="password">Пароль аккаунта</label>
        <input
          id="password"
          class="field"
          type="password"
          bind:value={password}
          autocomplete="current-password"
        />
        <button class="button primary" type="submit" disabled={busy || !password}>
          {busy ? 'Открываем…' : needCreate ? 'Создать ключ' : 'Открыть'}
        </button>
      </form>
    {/if}

    {#if error}
      <p class="error">{error}</p>
    {/if}

    {#if askReplace}
      <button class="button" onclick={() => (canUnlock ? open() : create())} disabled={busy}>
        Заменить ключ устройства
      </button>
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

  .muted {
    margin: 0;
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
