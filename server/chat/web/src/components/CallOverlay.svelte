<script lang="ts">
  import { onMount } from 'svelte';
  import type { ChatStore } from '../lib/chat/store.svelte';

  interface Props {
    store: ChatStore;
    title: string;
  }

  let { store, title }: Props = $props();

  const call = $derived(store.calls);

  let remoteEl: HTMLVideoElement | undefined = $state();
  let seconds = $state(0);
  let timer: number | null = null;

  onMount(() => {
    timer = window.setInterval(() => {
      seconds = call.startedAt ? Math.floor(Date.now() / 1000) - call.startedAt : 0;
    }, 1000);
    return () => {
      if (timer !== null) window.clearInterval(timer);
    };
  });

  // Поток приходит асинхронно: привязываем его к элементам, когда он появился.
  $effect(() => {
    const stream = call.remote;
    if (remoteEl && stream && remoteEl.srcObject !== stream) remoteEl.srcObject = stream;
  });

  function clock(): string {
    const total = Math.max(0, seconds);
    const mm = Math.floor(total / 60).toString().padStart(2, '0');
    const ss = (total % 60).toString().padStart(2, '0');
    return `${mm}:${ss}`;
  }

  function incoming(): string {
    const kind = call.video ? 'видеозвонок' : 'звонок';
    return `Входящий ${kind}`;
  }
</script>

{#if call.status !== 'idle'}
  <div class="call">
    <div class="head">
      <span class="avatar">{title.slice(0, 1).toUpperCase()}</span>
      <p class="name">{title || call.peer}</p>
      <p class="state">
        {#if call.status === 'incoming'}
          {incoming()}
        {:else if call.status === 'outgoing'}
          Звоним…
        {:else if call.status === 'active'}
          {clock()}
        {:else}
          {call.error || 'Звонок завершён'}
        {/if}
      </p>
    </div>

    {#if call.status === 'active' && call.remote}
      <video class="remote" bind:this={remoteEl} autoplay playsinline></video>
    {/if}

    <div class="actions">
      {#if call.status === 'incoming'}
        <button class="round accept" aria-label="Принять" onclick={() => void call.accept()}>
          <span class="ci ci-check"></span>
        </button>
        <button class="round decline" aria-label="Отклонить" onclick={() => void call.reject()}>
          <span class="ci ci-back"></span>
        </button>
      {:else if call.status === 'outgoing'}
        <button class="round decline" aria-label="Отменить" onclick={() => void call.hangup()}>
          <span class="ci ci-back"></span>
        </button>
      {:else if call.status === 'active'}
        <button
          class="round"
          class:on={call.muted}
          aria-label={call.muted ? 'Включить микрофон' : 'Выключить микрофон'}
          onclick={() => call.toggleMute()}
        >
          <span class="ci ci-smiley"></span>
        </button>
        {#if call.video}
          <button class="round" class:on={!call.localVideo} aria-label="Камера" onclick={() => call.toggleVideo()}>
            <span class="ci ci-people"></span>
          </button>
        {/if}
        <button class="round decline" aria-label="Завершить" onclick={() => void call.hangup()}>
          <span class="ci ci-back"></span>
        </button>
      {:else}
        <button class="round" aria-label="Закрыть" onclick={() => (call.status = 'idle')}>
          <span class="ci ci-check"></span>
        </button>
      {/if}
    </div>

    {#if call.status === 'active' && call.video}
      <p class="fine">Камера: {call.localVideo ? 'включена' : 'выключена'}</p>
    {/if}
  </div>
{/if}

<style>
  .call {
    position: fixed;
    inset: 0;
    z-index: 60;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 22px;
    padding: 24px;
    background: var(--bg);
  }

  .head {
    display: grid;
    justify-items: center;
    gap: 8px;
    text-align: center;
  }

  .avatar {
    display: grid;
    place-items: center;
    width: 92px;
    height: 92px;
    border-radius: 50%;
    background: var(--row-active);
    color: var(--text);
    font-size: 32px;
    font-weight: 600;
  }

  .name {
    margin: 0;
    font-size: 19px;
    font-weight: 600;
  }

  .state {
    margin: 0;
    color: var(--muted);
    font-size: 14px;
    font-variant-numeric: tabular-nums;
  }

  .remote {
    width: min(100%, 420px);
    max-height: 46vh;
    border-radius: 18px;
    background: #000;
    object-fit: cover;
  }

  .actions {
    display: flex;
    align-items: center;
    gap: 18px;
  }

  .round {
    display: grid;
    place-items: center;
    width: 56px;
    height: 56px;
    border: 0;
    border-radius: 50%;
    background: var(--field);
    color: var(--text);
    font-size: 22px;
    cursor: pointer;
  }

  .round.on {
    background: var(--accent);
    color: #16101f;
  }

  .round.accept {
    background: #6ee7a8;
    color: #10231a;
  }

  .round.decline {
    background: var(--danger);
    color: #fff;
  }
</style>
