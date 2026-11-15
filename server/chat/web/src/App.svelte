<script lang="ts">
  import { onMount } from 'svelte';
  import Approval from './components/Approval.svelte';
  import Home from './components/Home.svelte';
  import Login from './components/Login.svelte';
  import Unlock from './components/Unlock.svelte';
  import { chatApi } from './lib/api/chat';
  import { accountFromDevice } from './lib/auth/account';
  import {
    clearSession,
    enroll,
    loadSession,
    saveSession,
    type WebSession,
  } from './lib/auth/session';
  import { completeLogin, fetchUserInfo } from './lib/auth/sso';
  import { clearDeviceVault, hasVault } from './lib/auth/vault';
  import type { AccountKey } from './lib/crypto/account-key';
  import { unlockV2, type V2Keys } from './lib/chat/keys';
  import { applyPrefs, loadPrefs } from './lib/ui/prefs';

  type Stage = 'loading' | 'login' | 'approval' | 'unlock' | 'home';

  let stage = $state<Stage>('loading');
  let session = $state<WebSession | null>(null);
  let account = $state<AccountKey | null>(null);
  let v2 = $state<V2Keys | null>(null);
  let pending = $state<{ token: string; username: string; approvalId: string; code?: string } | null>(null);
  let vaultExists = $state(false);
  let loginError = $state('');

  const CALLBACK_PATH = '/v2/chat/sso/callback';

  onMount(() => {
    applyPrefs(loadPrefs());
    void boot();
  });

  async function boot() {
    if (location.pathname.replace(/\/$/, '') === CALLBACK_PATH) {
      try {
        const sso = await completeLogin(new URLSearchParams(location.search));
        const user = await fetchUserInfo(sso.token);
        const result = await enroll(sso.token, user.username);
        history.replaceState({}, '', '/v2/chat');
        if ('deviceId' in result) {
          await acceptSession(result);
        } else {
          pending = {
            token: sso.token,
            username: user.username,
            approvalId: result.approvalId,
            code: result.code,
          };
          stage = 'approval';
        }
      } catch (cause) {
        loginError = cause instanceof Error ? cause.message : 'Вход не удался';
        stage = 'login';
      }
      return;
    }

    const saved = loadSession();
    if (saved) {
      await acceptSession(saved, false);
    } else {
      stage = 'login';
    }
  }

  async function acceptSession(value: WebSession, persist = true) {
    if (persist) saveSession(value);
    session = value;
    pending = null;
    vaultExists = await hasVault();

    // Ключ уже лежит в хранилище устройства — пароль не спрашиваем.
    const stored = await accountFromDevice();
    if (stored) {
      account = stored;
      // v2-ключи устройства поднимаем без пароля: seed уже в сейфе.
      const keys = await unlockV2(chatApi(value.token), { username: value.username }).catch(
        () => null,
      );
      if (keys) {
        v2 = keys;
        stage = 'home';
        return;
      }
      // Без v2-ключа устройство не сможет ни принять, ни расшифровать конверты.
      v2 = null;
      stage = 'unlock';
      return;
    }
    stage = 'unlock';
  }

  function unlocked(value: AccountKey, keys: V2Keys | null) {
    account = value;
    v2 = keys;
    stage = 'home';
  }

  async function logout() {
    clearSession();
    // Выход означает «забыть устройство»: ключи стираются вместе с контейнером.
    await clearDeviceVault();
    session = null;
    account = null;
    v2 = null;
    stage = 'login';
  }

  function cancelApproval() {
    pending = null;
    stage = 'login';
  }
</script>

{#if stage === 'loading'}
  <main class="loading">Загрузка…</main>
{:else if stage === 'login'}
  <Login />
  {#if loginError}
    <p class="boot-error">{loginError}</p>
  {/if}
{:else if stage === 'approval' && pending}
  <Approval
    token={pending.token}
    username={pending.username}
    approvalId={pending.approvalId}
    code={pending.code}
    onready={(value) => void acceptSession(value)}
    oncancel={cancelApproval}
  />
{:else if stage === 'unlock' && session}
  <Unlock
    api={chatApi(session.token)}
    username={session.username}
    hasVault={vaultExists}
    onready={unlocked}
    onlogout={logout}
  />
{:else if stage === 'home' && session && account}
  <Home {session} {account} {v2} onlogout={logout} />
{/if}

<style>
  .loading {
    display: grid;
    place-items: center;
    min-height: 100%;
    color: var(--muted);
  }

  .boot-error {
    position: fixed;
    left: 50%;
    bottom: 20px;
    transform: translateX(-50%);
    margin: 0;
    padding: 10px 16px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--card);
    color: var(--danger);
    font-size: 13px;
    z-index: 10;
  }
</style>

