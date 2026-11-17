<script lang="ts">
  import { onMount } from 'svelte';
  import Approval from './components/Approval.svelte';
  import Home from './components/Home.svelte';
  import Login from './components/Login.svelte';
  import Setup from './components/Setup.svelte';
  import { chatApi } from './lib/api/chat';
  import { ApiError, setTokenRefresher } from './lib/api/http';
  import {
    clearSession,
    enroll,
    ensureDevice,
    ensureFresh,
    loadSession,
    saveSession,
    type RefreshPart,
    type WebSession,
  } from './lib/auth/session';
  import { completeLogin, fetchUserInfo } from './lib/auth/sso';
    import type { AccountKey } from './lib/crypto/account-key';
  import type { V2Keys } from './lib/chat/keys';
  import { applyPrefs, loadPrefs } from './lib/ui/prefs';

  type Stage = 'loading' | 'login' | 'approval' | 'setup' | 'home';

  let stage = $state<Stage>('loading');
  let session = $state<WebSession | null>(null);
  let account = $state<AccountKey | null>(null);
  let v2 = $state<V2Keys | null>(null);
  let pending = $state<{
    token: string;
    username: string;
    approvalId: string;
    code?: string;
    refresh?: RefreshPart;
  } | null>(null);
  let loginError = $state('');

  const CALLBACK_PATH = '/v2/chat/sso/callback';

  onMount(() => {
    applyPrefs(loadPrefs());
    setTokenRefresher(refreshSessionToken);
    void boot();
  });

  /** Обновляет токен после 401: сессия GhostID живёт дольше токена сервиса. */
  async function refreshSessionToken(stale: string): Promise<string | null> {
    if (!session || session.token !== stale) return null;
    const next = await ensureFresh({ ...session, expiresAt: 0 });
    if (!next) {
      clearSession();
      session = null;
      stage = 'login';
      return null;
    }
    session = next;
    const bound = await ensureDevice(next);
    session = bound;
    saveSession(bound);
    return bound.token;
  }

  async function boot() {
    if (location.pathname.replace(/\/$/, '') === CALLBACK_PATH) {
      try {
        const sso = await completeLogin(new URLSearchParams(location.search));
        const user = await fetchUserInfo(sso.token);
        const result = await enroll(sso.token, user.username, sso);
        history.replaceState({}, '', '/v2/chat');
        if ('deviceId' in result) {
          await acceptSession(result);
        } else {
          pending = {
            token: sso.token,
            username: user.username,
            approvalId: result.approvalId,
            code: result.code,
            refresh: sso,
          };
          stage = 'approval';
        }
      } catch (cause) {
        // Токен не принят — это не «вход не удался», а мёртвая сессия: чистим и просим войти.
        if (cause instanceof ApiError && cause.status === 401) {
          clearSession();
          session = null;
          loginError = 'Сессия GhostID не принята — войдите заново';
        } else {
          loginError = cause instanceof Error ? cause.message : 'Вход не удался';
        }
        stage = 'login';
      }
      return;
    }

    const saved = loadSession();
    if (saved) {
      // Токен мог истечь, пока вкладка была закрыта — продлеваем молча.
      const fresh = await ensureFresh(saved);
      if (fresh) {
        // Токен после refresh сервер не связывает с устройством — привязываем заново.
        await acceptSession(await ensureDevice(fresh));
        return;
      }
    }
    stage = 'login';
  }

  async function acceptSession(value: WebSession, persist = true) {
    if (persist) saveSession(value);
    session = value;
    pending = null;
    // Ключи поднимает Setup: он сам берёт их из сейфа браузера или создаёт новые.
    stage = 'setup';
  }

  function unlocked(value: AccountKey, keys: V2Keys | null) {
    account = value;
    v2 = keys;
    stage = 'home';
  }

  async function logout() {
    clearSession();
    // Ключ устройства не стираем: у аккаунта с режимом «только на устройстве» это
    // единственная копия, и после выхода войти было бы нечем.
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
    refresh={pending.refresh}
    onready={(value) => void acceptSession(value)}
    oncancel={cancelApproval}
  />
{:else if stage === 'setup' && session}
  <Setup
    api={chatApi(session.token)}
    username={session.username}
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

