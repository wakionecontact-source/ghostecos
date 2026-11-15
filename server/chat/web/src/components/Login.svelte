<script lang="ts">
  import { startLogin } from '../lib/auth/sso';

  let busy = $state(false);
  let error = $state('');

  async function login() {
    busy = true;
    error = '';
    try {
      await startLogin();
    } catch (cause) {
      busy = false;
      error = cause instanceof Error ? cause.message : 'Не удалось начать вход';
    }
  }
</script>

<main class="screen">
  <header class="topbar">
    <a class="brand" href="/home">Ghost<em>Chat</em></a>
    <span class="tag">через GhostID</span>
  </header>

  <section class="content">
    <div class="card entry fade-in">
      <h1>Вход</h1>
      <p class="note">Тот же аккаунт GhostID, что и в приложении.</p>

      <button class="button primary" onclick={login} disabled={busy}>
        {busy ? 'Переходим в GhostID…' : 'Войти через GhostID'}
      </button>

      {#if error}
        <p class="error">{error}</p>
      {/if}

      <p class="fine">Ключи создаются на устройстве. Сервер не видит содержимое сообщений.</p>
    </div>
  </section>
</main>

<style>
  .screen {
    display: flex;
    flex-direction: column;
    height: 100%;
  }

  .tag {
    color: var(--muted);
    font-size: 12px;
  }

  .content {
    flex: 1;
    display: grid;
    place-items: center;
    padding: 24px 16px;
  }

  .entry {
    display: grid;
    gap: 14px;
    width: min(100%, 380px);
    padding: 22px;
  }

  h1 {
    margin: 0;
    font-size: 20px;
    font-weight: 600;
    letter-spacing: -0.02em;
  }

  .note {
    margin: -6px 0 4px;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
  }

  .error {
    margin: 0;
    color: var(--danger);
    font-size: 13px;
  }

  .fine {
    margin: 0;
    color: var(--muted);
    font-size: 12px;
    line-height: 1.5;
  }
</style>
