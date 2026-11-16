<script lang="ts">
  import { onMount } from 'svelte';
  import type { ChatClient, IdentityMe, MyKeys } from '../lib/api/chat';
  import { ApiError } from '../lib/api/http';
  import { unlockAccount } from '../lib/auth/account';
  import { saveDeviceVault } from '../lib/auth/vault';
  import {
    activateV2Pair,
    checkV2Pair,
    ReplaceRequiredError,
    type V2Keys,
    type V2PairCheck,
  } from '../lib/chat/keys';
  import { generateKeys, publishAccountKey, type KeyStorageMode } from '../lib/chat/provision';
  import type { AccountKey } from '../lib/crypto/account-key';

  interface Props {
    api: ChatClient;
    username: string;
    /** Пароль из сейфа GhostID: с ним вводить ничего не нужно. */
    initialPassword?: string;
    onready: (account: AccountKey, v2: V2Keys | null) => void;
    onlogout: () => void;
  }

  let { api, username, initialPassword = '', onready, onlogout }: Props = $props();

  let keys = $state<MyKeys | null>(null);
  let identity = $state<IdentityMe | null>(null);
  let password = $state('');
  let busy = $state(false);
  let error = $state('');
  let askReplace = $state(false);
  let askRotate = $state(false);
  let account = $state<AccountKey | null>(null);
  let decision = $state<V2PairCheck | null>(null);
  let autoTried = false;

  const canUnlock = $derived(!!keys?.encrypted_private_key && !!keys?.key_salt);
  const hasIdentity = $derived(!!identity?.identity_pub);
  const needCreate = $derived(!hasIdentity && !canUnlock);

  onMount(async () => {
    // Пароль из сейфа GhostID подставляем сразу: пользователю остаётся подтвердить.
    if (initialPassword) password = initialPassword;
    try {
      const [keyState, identityState] = await Promise.all([
        api.myKeys(),
        api.myIdentity().catch(() => null),
      ]);
      keys = keyState;
      identity = identityState;
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Нет связи с сервером';
      return;
    }
    // Пароль уже дан GhostID: открываем сами, без лишнего нажатия.
    if (!autoTried && initialPassword && canUnlock) {
      autoTried = true;
      await open();
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

  /** Новый аккаунт: копия v1 на сервере — по выбору, локальный режим без пароля. */
  async function create(mode: KeyStorageMode, replace = askReplace) {
    busy = true;
    error = '';
    try {
      const generated = await generateKeys();
      const secret = mode === 'server' ? password : '';
      await publishAccountKey(api, username, generated.account, mode, secret, replace);
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
  async function publishV2(uploadCopy: boolean, rotate = false) {
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
        rotate: rotate || state === 'locked',
      });
      decision = null;
      finish(v2);
    } catch (cause) {
      // Сервер не даёт сменить identity без явного согласия — показываем кнопку замены.
      if (cause instanceof ApiError && cause.status === 409) askRotate = true;
      fail(cause);
    } finally {
      busy = false;
    }
  }

  function submit(event: SubmitEvent) {
    event.preventDefault();
    if (!password || busy || decision || !canUnlock) return;
    void open();
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
      {#if askRotate}
        <button class="button" onclick={() => publishV2(false, true)} disabled={busy}>
          Заменить identity
        </button>
        <p class="muted">Прежняя identity останется у контактов до их обновления ключей.</p>
      {/if}
      <button class="link" onclick={() => finish(null)} disabled={busy}>
        Продолжить без ключа v2
      </button>
    {:else if decision?.state === 'locked'}
      <p class="muted">Копии ключа v2 на сервере нет.</p>
      <button class="button primary" onclick={() => publishV2(true)} disabled={busy}>
        Создать новый ключ v2
      </button>
      <p class="muted">Прежние сообщения v2 останутся нечитаемыми.</p>
      <button class="link" onclick={() => finish(null)} disabled={busy}>
        Продолжить без ключа v2
      </button>
    {:else if !canUnlock}
      <p class="muted">
        Ключ этого аккаунта хранится только на устройстве, а в этом браузере его нет — открывать
        нечего.
      </p>
      {#if askReplace}
        <button
          class="button primary"
          type="button"
          onclick={() => create('local', true)}
          disabled={busy}
        >
          Заменить ключ на этом устройстве
        </button>
        <p class="muted">
          У аккаунта уже опубликован ключ. Замена отвяжет его от прежних сообщений — они станут
          нечитаемыми.
        </p>
      {:else}
        <button class="button primary" type="button" onclick={() => create('local')} disabled={busy}>
          Создать ключ на этом устройстве
        </button>
        <p class="muted">Старые зашифрованные сообщения после этого станут нечитаемыми.</p>
      {/if}
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
        {#if needCreate}
          <button
            class="button primary"
            type="button"
            onclick={() => create('server')}
            disabled={busy || !password}
          >
            Копия на сервере
          </button>
          <button class="button" type="button" onclick={() => create('local')} disabled={busy}>
            Только на устройстве
          </button>
        {:else}
          <button class="button primary" type="submit" disabled={busy || !password}>
            {busy ? 'Открываем…' : 'Открыть'}
          </button>
        {/if}
      </form>
    {/if}

    {#if error}
      <p class="error">{error}</p>
    {/if}

    {#if askReplace && canUnlock}
      <button class="button" onclick={() => open()} disabled={busy}>
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
