<script lang="ts">
  import { onMount, tick } from 'svelte';
  import type { ChatStore } from '../lib/chat/store.svelte';
  import type { FilePayload, StoredMessage } from '../lib/chat/messages';
  import { dayKey, dayLabel, timeLabel } from '../lib/chat/time';

  interface Props {
    store: ChatStore;
    peer: string;
    title: string;
    onclose: () => void;
  }

  let { store, peer, title, onclose }: Props = $props();

  let messages = $state<StoredMessage[]>([]);
  let draft = $state('');
  let error = $state('');
  let sending = $state(false);
  let uploading = $state(false);
  let fileInput: HTMLInputElement | undefined = $state();
  let loading = $state(true);
  let scroller: HTMLDivElement | undefined = $state();

  const online = $derived(store.presence[peer]);
  const known = $derived(online !== undefined);

  onMount(() => {
    let alive = true;

    const reload = async () => {
      const list = await store.loadThread(peer);
      if (!alive) return;
      messages = list;
      prefetch(list);
      await scroll(false);
    };

    void (async () => {
      try {
        messages = await store.openThread(peer);
        prefetch(messages);
      } catch (cause) {
        error = cause instanceof Error ? cause.message : 'Не удалось открыть чат';
      } finally {
        loading = false;
        await scroll(true);
      }
    })();

    const off = store.subscribe(() => {
      store.markRead(peer);
      void reload();
    });
    const presenceTimer = window.setInterval(() => store.askPresence(peer), 5_000);
    store.askPresence(peer, true);

    return () => {
      alive = false;
      off();
      window.clearInterval(presenceTimer);
    };
  });

  async function scroll(force: boolean) {
    await tick();
    if (!scroller) return;
    const nearBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 120;
    if (force || nearBottom) scroller.scrollTop = scroller.scrollHeight;
  }

  async function send() {
    const text = draft.trim();
    if (!text || sending) return;
    sending = true;
    error = '';
    try {
      await store.send(peer, text);
      draft = '';
      messages = await store.loadThread(peer);
      await scroll(true);
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Сообщение не отправлено';
    } finally {
      sending = false;
    }
  }

  function onKeydown(event: KeyboardEvent) {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      void send();
    }
  }

  async function attach(event: Event) {
    const input = event.currentTarget as HTMLInputElement;
    const file = input.files?.[0];
    input.value = '';
    if (!file || uploading) return;
    uploading = true;
    error = '';
    const caption = draft.trim();
    try {
      await store.sendFile(peer, file, caption);
      if (caption) draft = '';
      messages = await store.loadThread(peer);
      await scroll(true);
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Вложение не отправлено';
    } finally {
      uploading = false;
    }
  }

  /* ── Вложения ──────────────────────────────── */

  let media = $state<Record<number, string>>({});
  let mediaErrors = $state<Record<number, boolean>>({});
  const pendingMedia = new Set<number>();

  function isImage(file: FilePayload): boolean {
    return file.mime.startsWith('image/');
  }

  function isAudio(file: FilePayload): boolean {
    return !!file.voice || file.mime.startsWith('audio/');
  }

  function formatSize(bytes: number): string {
    if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} МБ`;
    if (bytes >= 1024) return `${Math.round(bytes / 1024)} КБ`;
    return `${bytes} Б`;
  }

  async function loadMedia(file: FilePayload): Promise<void> {
    if (media[file.file_id] || pendingMedia.has(file.file_id)) return;
    pendingMedia.add(file.file_id);
    try {
      const { blob } = await store.download(file);
      media = { ...media, [file.file_id]: URL.createObjectURL(blob) };
    } catch {
      mediaErrors = { ...mediaErrors, [file.file_id]: true };
    } finally {
      pendingMedia.delete(file.file_id);
    }
  }

  async function saveMedia(file: FilePayload): Promise<void> {
    try {
      const { blob, name } = await store.download(file);
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = name;
      link.click();
      window.setTimeout(() => URL.revokeObjectURL(url), 10_000);
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось скачать файл';
    }
  }

  /** Картинки подгружаем сразу, остальное — по действию пользователя. */
  function prefetch(list: StoredMessage[]): void {
    for (const message of list) {
      if (message.file && isImage(message.file)) void loadMedia(message.file);
    }
  }

  /* ── Эмодзи ──────────────────────────────────── */

  const EMOJI = [
    '😀', '😄', '😁', '😊', '🙂', '😉', '😍', '😘',
    '😎', '🤔', '😐', '😴', '😢', '😭', '😡', '🤯',
    '🥳', '🤗', '🤝', '👍', '👎', '👏', '🙏', '✌️',
    '❤️', '🔥', '✨', '🎉', '💯', '⚡', '🌙', '☀️',
    '🍀', '🎧', '🎮', '📎', '📱', '💻', '🔒', '🛡️',
  ];

  let emojiOpen = $state(false);
  let inputEl: HTMLTextAreaElement | undefined = $state();

  function insertEmoji(emoji: string): void {
    const area = inputEl;
    if (!area) {
      draft += emoji;
      return;
    }
    const start = area.selectionStart ?? draft.length;
    const end = area.selectionEnd ?? start;
    draft = draft.slice(0, start) + emoji + draft.slice(end);
    void tick().then(() => {
      area.focus();
      area.selectionStart = start + emoji.length;
      area.selectionEnd = start + emoji.length;
    });
  }

  /* ── Действия с чатом ───────────────────────── */

  let menuOpen = $state(false);
  let notice = $state('');

  function flash(text: string): void {
    notice = text;
    window.setTimeout(() => {
      if (notice === text) notice = '';
    }, 2600);
  }

  async function clearHistory(): Promise<void> {
    menuOpen = false;
    if (!window.confirm('Очистить историю этого чата на всех устройствах?')) return;
    try {
      await store.clearChat(peer);
      messages = [];
      flash('История очищена');
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось очистить историю';
    }
  }

  async function blockPeer(): Promise<void> {
    menuOpen = false;
    if (!window.confirm(`Заблокировать @${peer}? Сообщения от него больше не придут.`)) return;
    try {
      await store.block(peer);
      flash('Пользователь заблокирован');
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось заблокировать';
    }
  }
</script>

<section class="thread">
  <header class="appbar">
    <button class="back" aria-label="Назад" onclick={onclose}>
      <span class="ci ci-back"></span>
    </button>

    <span class="avatar-wrap">
      <span class="avatar">{(title || peer).slice(0, 1).toUpperCase()}</span>
      {#if known}
        <span class="dot" class:on={online}></span>
      {/if}
    </span>

    <span class="who">
      <span class="name">{title || peer}</span>
      <span class="sub">
        @{peer}{#if known} · {online ? 'в сети' : 'не в сети'}{/if}
      </span>
    </span>

    <button
      class="menu-btn"
      aria-label="Действия с чатом"
      aria-expanded={menuOpen}
      onclick={() => (menuOpen = !menuOpen)}
    >···</button>
    {#if menuOpen}
      <div class="menu" role="menu">
        <button class="menu-item" role="menuitem" onclick={clearHistory}>Очистить историю</button>
        <button class="menu-item danger" role="menuitem" onclick={blockPeer}>Заблокировать</button>
      </div>
    {/if}
  </header>
  {#if notice}<p class="notice">{notice}</p>{/if}

  <div class="messages" bind:this={scroller}>
    {#if loading}
      <p class="hint center">Загружаем сообщения…</p>
    {:else if messages.length === 0}
      <p class="hint center">Сообщений пока нет — напиши первым.</p>
    {:else}
      {#each messages as message, index (message.uid)}
        {@const prev = index > 0 ? messages[index - 1] : null}
        {@const newDay = !prev || dayKey(prev.ts) !== dayKey(message.ts)}
        {@const grouped = !!prev && !newDay && prev.mine === message.mine}
        {#if newDay}
          <div class="day"><span>{dayLabel(message.ts)}</span></div>
        {/if}
        <div class="row" class:mine={message.mine} class:grouped={grouped}>
          <div class="bubble" class:mine={message.mine}>
            <span class="meta">
              <time>{timeLabel(message.ts)}</time>
              {#if message.mine}
                <span class="tick" class:read={message.status === 'read'}>
                  {#if message.status === 'read'}
                    <span class="ci ci-check"></span>
                    <span class="ci ci-check"></span>
                  {:else if message.status === 'delivered'}
                    <span class="ci ci-check"></span>
                  {:else if message.status === 'saved'}
                    <span class="ci ci-saved"></span>
                  {:else}
                    <span class="ci ci-clock"></span>
                  {/if}
                </span>
              {/if}
            </span>
            {#if message.file}
              {@const file = message.file}
              {#if isImage(file)}
                <button class="media" type="button" onclick={() => loadMedia(file)} title={file.file_name}>
                  {#if media[file.file_id]}
                    <img src={media[file.file_id]} alt={file.file_name} />
                  {:else if mediaErrors[file.file_id]}
                    <span class="media-note">Файл недоступен: {file.file_name}</span>
                  {:else}
                    <span class="media-note">Загрузка изображения…</span>
                  {/if}
                </button>
              {:else if isAudio(file)}
                {#if media[file.file_id]}
                  <audio class="audio" controls src={media[file.file_id]}></audio>
                {:else}
                  <button class="file-card" type="button" onclick={() => loadMedia(file)}>
                    <span class="ci ci-saved"></span>
                    <span class="file-text">
                      <span class="file-name">Голосовое сообщение</span>
                      <span class="file-meta">{formatSize(file.size)} · загрузить</span>
                    </span>
                  </button>
                {/if}
              {:else}
                <button class="file-card" type="button" onclick={() => saveMedia(file)}>
                  <span class="ci ci-saved"></span>
                  <span class="file-text">
                    <span class="file-name">{file.file_name}</span>
                    <span class="file-meta">{formatSize(file.size)} · скачать</span>
                  </span>
                </button>
              {/if}
            {/if}
            {#if message.text}
              <span class="text">{message.text}</span>
            {/if}
          </div>
        </div>
      {/each}
    {/if}
  </div>

  {#if error}<p class="error">{error}</p>{/if}

  <form
    class="composer"
    onsubmit={(event) => {
      event.preventDefault();
      void send();
    }}
  >
    <button
      class="icon-btn"
      type="button"
      aria-label="Вложение"
      title="Вложение"
      disabled={uploading}
      onclick={() => fileInput?.click()}
    >
      {#if uploading}
        <span class="spinner dark"></span>
      {:else}
        <span class="ci ci-paperclip"></span>
      {/if}
    </button>
    <input
      class="file-input"
      type="file"
      bind:this={fileInput}
      onchange={attach}
      tabindex="-1"
      aria-hidden="true"
    />
    <button
      class="icon-btn"
      type="button"
      aria-label="Эмодзи"
      title="Эмодзи"
      aria-expanded={emojiOpen}
      onclick={() => (emojiOpen = !emojiOpen)}
    >
      <span class="ci ci-smiley"></span>
    </button>
    {#if emojiOpen}
      <div class="emoji-panel" role="dialog" aria-label="Эмодзи">
        {#each EMOJI as emoji (emoji)}
          <button class="emoji" type="button" onclick={() => insertEmoji(emoji)}>{emoji}</button>
        {/each}
      </div>
    {/if}
    <textarea
      class="input"
      bind:value={draft}
      bind:this={inputEl}
      placeholder="Сообщение"
      rows="1"
      onkeydown={onKeydown}
    ></textarea>
    <button class="send" type="submit" disabled={sending || !draft.trim()} aria-label="Отправить">
      {#if sending}
        <span class="spinner"></span>
      {:else}
        <span class="ci ci-send"></span>
      {/if}
    </button>
  </form>
</section>

<style>
  .thread {
    display: flex;
    flex: 1 1 auto;
    flex-direction: column;
    width: 100%;
    height: 100%;
    min-height: 0;
    background: var(--bg);
  }

  .appbar {
    position: relative;
    display: flex;
    align-items: center;
    flex: none;
    height: 60px;
    padding-right: 6px;
    border-bottom: 1px solid var(--border);
    background: var(--header-blur);
    backdrop-filter: blur(18px) saturate(1.4);
    -webkit-backdrop-filter: blur(18px) saturate(1.4);
  }

  .menu-btn {
    flex: none;
    margin-left: auto;
    padding: 0 10px;
    height: 34px;
    border: 0;
    border-radius: 9px;
    background: transparent;
    color: var(--muted);
    font-size: 17px;
    letter-spacing: 1px;
    cursor: pointer;
  }

  .menu-btn:hover {
    background: var(--row-hover);
  }

  .menu {
    position: absolute;
    top: 52px;
    right: 8px;
    z-index: 6;
    display: grid;
    min-width: 190px;
    padding: 6px;
    border: 1px solid var(--border);
    border-radius: 12px;
    background: var(--card);
    box-shadow: 0 14px 34px rgba(0, 0, 0, 0.45);
  }

  .menu-item {
    padding: 9px 10px;
    border: 0;
    border-radius: 8px;
    background: transparent;
    color: var(--text);
    font: inherit;
    font-size: 13px;
    text-align: left;
    cursor: pointer;
  }

  .menu-item:hover {
    background: var(--row-hover);
  }

  .menu-item.danger {
    color: var(--danger);
  }

  .notice {
    margin: 0;
    padding: 8px 14px;
    background: rgba(179, 154, 244, 0.14);
    color: var(--accent);
    font-size: 12px;
    text-align: center;
  }

  .back {
    display: grid;
    place-items: center;
    flex: none;
    width: 56px;
    height: 60px;
    border: 0;
    background: transparent;
    color: var(--text);
    font-size: 22px;
    cursor: pointer;
  }

  .back:hover {
    background: var(--row-hover);
  }

  .avatar-wrap {
    position: relative;
    flex: none;
    width: 32px;
    height: 32px;
    margin-right: 8px;
  }

  .avatar {
    display: grid;
    place-items: center;
    width: 32px;
    height: 32px;
    border-radius: 50%;
    background: var(--row-active);
    font-size: 13px;
    font-weight: 600;
  }

  .dot {
    position: absolute;
    right: -2px;
    bottom: -2px;
    width: 11px;
    height: 11px;
    border: 2px solid var(--bg);
    border-radius: 50%;
    background: rgba(119, 119, 130, 0.35);
  }

  .dot.on {
    background: #6ee7a8;
  }

  .who {
    display: grid;
    min-width: 0;
  }

  .name {
    overflow: hidden;
    font-size: 15px;
    font-weight: 700;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .sub {
    overflow: hidden;
    color: var(--muted);
    font-size: 11px;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .messages {
    flex: 1;
    display: flex;
    flex-direction: column;
    padding: 8px 12px 6px;
    overflow-y: auto;
  }

  .day {
    display: flex;
    justify-content: center;
    margin: 12px 0 4px;
  }

  .day span {
    padding: 3px 10px;
    border-radius: 20px;
    background: rgba(255, 255, 255, 0.06);
    color: var(--muted);
    font-size: 11px;
  }

  .row {
    display: flex;
    justify-content: flex-start;
    margin-top: 5px;
  }

  .row.mine {
    justify-content: flex-end;
  }

  .row.grouped {
    margin-top: 1px;
  }

  .bubble {
    max-width: min(600px, calc(100% - 24px));
    padding: 8px 12px;
    border-radius: 12px 12px 12px 4.5px;
    background: var(--card);
    color: var(--text);
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.22);
    font-size: 15px;
    line-height: 1.35;
    overflow-wrap: anywhere;
  }

  .bubble.mine {
    border-radius: 12px 12px 4.5px 12px;
    background: linear-gradient(135deg, var(--bubble-mine-from), var(--bubble-mine-to));
    color: var(--bubble-mine-text);
  }

  .text {
    white-space: pre-wrap;
  }

  /* ── Вложения ──────────────────────────────── */
  .media {
    display: block;
    max-width: 100%;
    margin: 0 0 4px;
    padding: 0;
    border: 0;
    border-radius: 9px;
    background: rgba(0, 0, 0, 0.18);
    color: inherit;
    cursor: pointer;
    overflow: hidden;
  }

  .media img {
    display: block;
    max-width: 100%;
    max-height: 320px;
    object-fit: cover;
  }

  .media-note {
    display: block;
    padding: 14px 16px;
    color: inherit;
    font-size: 12px;
    opacity: 0.8;
  }

  .audio {
    display: block;
    width: min(260px, 100%);
    margin: 2px 0 4px;
  }

  .file-card {
    display: flex;
    align-items: center;
    gap: 10px;
    margin: 2px 0 4px;
    padding: 8px 10px;
    border: 0;
    border-radius: 9px;
    background: rgba(0, 0, 0, 0.2);
    color: inherit;
    font: inherit;
    text-align: left;
    cursor: pointer;
  }

  .bubble:not(.mine) .file-card {
    background: var(--field);
  }

  .file-card .ci {
    flex: none;
    font-size: 20px;
    opacity: 0.85;
  }

  .file-text {
    display: grid;
    min-width: 0;
    gap: 2px;
  }

  .file-name {
    overflow: hidden;
    font-size: 13px;
    font-weight: 600;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .file-meta {
    font-size: 11px;
    opacity: 0.7;
  }

  /* Плавающая мета садится к последней строке, как inline-время в приложении. */
  .meta {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    float: right;
    margin: 4px 0 0 8px;
    color: var(--muted);
    font-size: 10px;
    font-variant-numeric: tabular-nums;
    line-height: 1;
  }

  .bubble.mine .meta {
    color: rgba(251, 248, 255, 0.72);
  }

  .tick {
    display: inline-flex;
    align-items: center;
    font-size: 13px;
  }

  .tick .ci + .ci {
    margin-left: -5px;
  }

  .tick.read {
    color: #bcd4ff;
  }

  .hint {
    margin: 0;
    padding: 14px;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
  }

  .hint.center {
    margin-top: 24px;
    text-align: center;
  }

  .composer {
    position: relative;
    display: flex;
    align-items: flex-end;
    gap: 4px;
    flex: none;
    padding: 8px;
    border-top: 1px solid rgba(179, 154, 244, 0.17);
    background: linear-gradient(
      to top,
      rgba(9, 9, 11, 0.86),
      rgba(9, 9, 11, 0.5) 60%,
      rgba(9, 9, 11, 0.08)
    );
  }

  .emoji-panel {
    position: absolute;
    right: 8px;
    bottom: calc(100% + 6px);
    z-index: 5;
    display: grid;
    grid-template-columns: repeat(8, 1fr);
    gap: 2px;
    width: min(320px, calc(100vw - 24px));
    padding: 8px;
    border: 1px solid var(--border);
    border-radius: 14px;
    background: var(--card);
    box-shadow: 0 12px 32px rgba(0, 0, 0, 0.45);
  }

  .emoji {
    display: grid;
    place-items: center;
    width: 34px;
    height: 34px;
    border: 0;
    border-radius: 8px;
    background: transparent;
    font-size: 20px;
    line-height: 1;
    cursor: pointer;
  }

  .emoji:hover {
    background: var(--row-hover);
  }

  .icon-btn {
    display: grid;
    place-items: center;
    width: 34px;
    height: 38px;
    flex: none;
    border: 0;
    background: transparent;
    color: var(--muted);
    font-size: 20px;
    cursor: pointer;
  }

  .icon-btn:disabled {
    cursor: default;
    opacity: 0.6;
  }

  .file-input {
    display: none;
  }

  .spinner.dark {
    border-color: rgba(255, 255, 255, 0.25);
    border-top-color: var(--muted);
  }

  .input {
    flex: 1;
    min-height: 38px;
    max-height: 132px;
    padding: 9px 4px;
    border: 0;
    background: transparent;
    color: var(--text);
    font-size: 15px;
    line-height: 1.35;
    outline: 0;
    resize: none;
  }

  .input::placeholder {
    color: var(--muted);
  }

  .send {
    display: grid;
    place-items: center;
    width: 38px;
    height: 38px;
    flex: none;
    border: 0;
    border-radius: 50%;
    background: var(--accent);
    color: #16101f;
    font-size: 20px;
    cursor: pointer;
  }

  .send:disabled {
    opacity: 0.4;
    cursor: default;
  }

  .spinner {
    width: 14px;
    height: 14px;
    border: 2px solid rgba(22, 16, 31, 0.35);
    border-top-color: #16101f;
    border-radius: 50%;
    animation: spin 0.7s linear infinite;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  .error {
    margin: 0 14px 6px;
    color: var(--danger);
    font-size: 13px;
  }
</style>

