<script lang="ts">
  import { pollApproval, type RefreshPart, type WebSession } from '../lib/auth/session';

  interface Props {
    token: string;
    username: string;
    approvalId: string;
    code?: string;
    refresh?: RefreshPart;
    onready: (session: WebSession) => void;
    oncancel: () => void;
  }

  let { token, username, approvalId, code = '', refresh, onready, oncancel }: Props = $props();
  let expired = $state(false);
  let error = $state('');
  let timer: number | undefined;

  $effect(() => {
    let stopped = false;

    const poll = async () => {
      try {
        const result = await pollApproval(token, approvalId, username, refresh);
        if (stopped) return;
        if (typeof result === 'object' && result !== null) {
          onready(result);
          return;
        }
        if (result === 'expired') {
          expired = true;
          return;
        }
        timer = window.setTimeout(poll, 3000);
      } catch (cause) {
        if (stopped) return;
        error = cause instanceof Error ? cause.message : 'Ошибка проверки одобрения';
        timer = window.setTimeout(poll, 5000);
      }
    };

    poll();
    return () => {
      stopped = true;
      if (timer !== undefined) window.clearTimeout(timer);
    };
  });
</script>

<main class="screen">
  <header class="topbar">
    <a class="brand" href="/home">Ghost<em>Chat</em></a>
    <span class="tag">@безопасность</span>
  </header>

  <section class="content">
    <div class="card entry fade-in">
      <h1>Подтверди вход</h1>
      <p class="note">Открой GhostChat на телефоне: «Устройства» → «Ожидают подтверждения».</p>

      {#if code}
        <div class="code">{code}</div>
      {/if}

      {#if expired}
        <p class="status">Запрос истёк.</p>
      {:else}
        <p class="status">Ждём одобрения…</p>
      {/if}

      {#if error}
        <p class="error">{error}</p>
      {/if}

      <button class="button" onclick={oncancel}>Вернуться</button>
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
    gap: 12px;
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
    margin: -6px 0 2px;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
  }

  .code {
    justify-self: start;
    padding: 10px 14px;
    border-radius: 8px;
    background: var(--row-active);
    color: var(--accent);
    font-size: 24px;
    font-weight: 600;
    letter-spacing: 0.18em;
  }

  .status {
    margin: 0;
    color: var(--muted);
    font-size: 13px;
  }

  .error {
    margin: 0;
    color: var(--danger);
    font-size: 13px;
  }
</style>
