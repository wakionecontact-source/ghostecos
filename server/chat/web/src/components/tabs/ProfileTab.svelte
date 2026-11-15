<script lang="ts">
  import { deleteAvatar, updateProfile, uploadAvatar, type MeProfile } from '../../lib/api/me';
  import type { WebSession } from '../../lib/auth/session';

  interface Props {
    session: WebSession;
    me: MeProfile | null;
    error: string;
    onrefresh: () => Promise<void>;
    onsettings: () => void;
    onlogout: () => void;
  }

  let { session, me, error, onrefresh, onsettings, onlogout }: Props = $props();

  const name = $derived(me?.display_name || session.username);
  const initial = $derived((name || '?').slice(0, 1).toUpperCase());

  let editing = $state(false);
  let displayName = $state('');
  let about = $state('');
  let busy = $state('');
  let formError = $state('');
  let notice = $state('');
  let avatarInput: HTMLInputElement | undefined = $state();

  function count(value: number | undefined): string {
    if (!value) return '0';
    if (value >= 1000) return `${(value / 1000).toFixed(value >= 10_000 ? 0 : 1)}K`;
    return String(value);
  }

  function startEdit(): void {
    displayName = me?.display_name || session.username;
    about = me?.about ?? '';
    formError = '';
    editing = true;
  }

  async function saveProfile(): Promise<void> {
    if (busy) return;
    const cleanName = displayName.trim();
    if (!cleanName) {
      formError = 'Имя не может быть пустым';
      return;
    }
    busy = 'profile';
    formError = '';
    try {
      await updateProfile(session.token, {
        display_name: cleanName,
        about: about.trim(),
      });
      await onrefresh();
      editing = false;
      notice = 'Профиль сохранён';
    } catch (cause) {
      formError = cause instanceof Error ? cause.message : 'Не удалось сохранить профиль';
    } finally {
      busy = '';
    }
  }

  async function changeAvatar(event: Event): Promise<void> {
    const input = event.currentTarget as HTMLInputElement;
    const file = input.files?.[0];
    input.value = '';
    if (!file) return;
    busy = 'avatar';
    formError = '';
    try {
      await uploadAvatar(session.token, file);
      await onrefresh();
      notice = 'Аватар обновлён';
    } catch (cause) {
      formError = cause instanceof Error ? cause.message : 'Не удалось загрузить аватар';
    } finally {
      busy = '';
    }
  }

  async function removeAvatar(): Promise<void> {
    if (!window.confirm('Убрать аватар?')) return;
    busy = 'avatar';
    try {
      await deleteAvatar(session.token);
      await onrefresh();
      notice = 'Аватар убран';
    } catch (cause) {
      formError = cause instanceof Error ? cause.message : 'Не удалось убрать аватар';
    } finally {
      busy = '';
    }
  }
</script>

<div class="tab">
  <div class="hero">
    <button class="avatar-slot" onclick={() => avatarInput?.click()} aria-label="Сменить аватар">
      {#if me?.avatar_url}
        <img class="avatar big" src={me.avatar_url} alt={name} />
      {:else}
        <span class="avatar big">{initial}</span>
      {/if}
      <span class="avatar-hint">{busy === 'avatar' ? '…' : 'Сменить'}</span>
    </button>
    <input
      class="file-input"
      type="file"
      accept="image/jpeg,image/png,image/webp"
      bind:this={avatarInput}
      onchange={changeAvatar}
      tabindex="-1"
      aria-hidden="true"
    />
    <h1 class="name">{name}</h1>
    <p class="login">@{session.username}</p>
    {#if me?.about}
      <p class="about">{me.about}</p>
    {/if}
    {#if me?.is_admin || me?.is_moderator}
      <p class="role">{me?.is_admin ? 'администратор' : 'модератор'}</p>
    {/if}
    {#if me?.avatar_url}
      <button class="link" onclick={removeAvatar} disabled={busy === 'avatar'}>Убрать аватар</button>
    {/if}
  </div>

  <div class="stats">
    <div><b>{count(me?.posts_count)}</b><span>посты</span></div>
    <div><b>{count(me?.followers_count)}</b><span>подписчики</span></div>
    <div><b>{count(me?.following_count)}</b><span>подписки</span></div>
  </div>

  {#if error}<p class="error">{error}</p>{/if}
  {#if formError}<p class="error">{formError}</p>{/if}
  {#if notice}<p class="notice">{notice}</p>{/if}

  {#if editing}
    <div class="editor">
      <label class="field">
        <span>Имя</span>
        <input bind:value={displayName} maxlength="100" placeholder="Как вас называть" />
      </label>
      <label class="field">
        <span>О себе</span>
        <textarea bind:value={about} maxlength="256" rows="3" placeholder="Коротко о себе"></textarea>
      </label>
      <div class="editor-actions">
        <button class="button ghost" onclick={() => (editing = false)} disabled={busy === 'profile'}>Отмена</button>
        <button class="button primary" onclick={saveProfile} disabled={busy === 'profile'}>
          {busy === 'profile' ? 'Сохраняем…' : 'Сохранить'}
        </button>
      </div>
    </div>
  {:else}
    <div class="actions">
      <button class="row" onclick={startEdit}>
        <span class="label">Редактировать профиль</span>
        <span class="chev">›</span>
      </button>
      <button class="row" onclick={onsettings}>
        <span class="label">Настройки</span>
        <span class="chev">›</span>
      </button>
      <button class="row danger" onclick={onlogout}>
        <span class="label">Выйти</span>
      </button>
    </div>
  {/if}

  <p class="device">Устройство #{session.deviceId} · сессия до {new Date(session.expiresAt).toLocaleDateString()}</p>
</div>

<style>
  .tab {
    height: 100%;
    width: 100%;
    max-width: 720px;
    margin: 0 auto;
    overflow-y: auto;
    padding-bottom: 24px;
  }

  .hero {
    display: grid;
    justify-items: center;
    gap: 4px;
    padding: 28px 20px 16px;
    text-align: center;
  }

  .avatar-slot {
    position: relative;
    border: 0;
    padding: 0;
    background: transparent;
    cursor: pointer;
  }

  .avatar-slot .avatar.big {
    display: grid;
    place-items: center;
    width: 88px;
    height: 88px;
    border-radius: 50%;
    background: var(--row-active);
    color: var(--text);
    font-size: 32px;
    font-weight: 600;
    object-fit: cover;
  }

  .avatar-hint {
    position: absolute;
    right: -4px;
    bottom: 0;
    padding: 2px 8px;
    border-radius: 999px;
    background: var(--accent);
    color: #16101f;
    font-size: 10px;
    font-weight: 600;
  }

  .file-input {
    display: none;
  }

  .name {
    margin: 10px 0 0;
    font-size: 19px;
    font-weight: 700;
    letter-spacing: -0.01em;
  }

  .login {
    margin: 0;
    color: var(--muted);
    font-size: 13px;
  }

  .about {
    margin: 6px 0 0;
    max-width: 34ch;
    color: var(--text);
    font-size: 13px;
    line-height: 1.45;
    opacity: 0.85;
  }

  .role {
    margin: 4px 0 0;
    color: var(--accent);
    font-size: 11px;
    text-transform: lowercase;
  }

  .link {
    margin-top: 6px;
    border: 0;
    background: transparent;
    color: var(--muted);
    font-size: 11px;
    text-decoration: underline;
    cursor: pointer;
  }

  .stats {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    margin: 8px 16px 0;
    padding: 12px 0;
    border-radius: 14px;
    background: var(--card);
  }

  .stats div {
    display: grid;
    justify-items: center;
    gap: 2px;
  }

  .stats b {
    font-size: 15px;
    font-weight: 700;
  }

  .stats span {
    color: var(--muted);
    font-size: 11px;
  }

  .actions {
    margin: 16px 16px 0;
    border-radius: 14px;
    overflow: hidden;
    background: var(--card);
  }

  .row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    width: 100%;
    padding: 14px 16px;
    border: 0;
    background: transparent;
    color: inherit;
    font: inherit;
    font-size: 15px;
    text-align: left;
    cursor: pointer;
  }

  .row + .row {
    border-top: 1px solid var(--border);
  }

  .row:hover {
    background: var(--row-hover);
  }

  .row.danger .label {
    color: var(--danger);
  }

  .chev {
    color: var(--muted);
    font-size: 18px;
  }

  .editor {
    display: grid;
    gap: 10px;
    margin: 16px 16px 0;
    padding: 14px;
    border-radius: 14px;
    background: var(--card);
  }

  .field {
    display: grid;
    gap: 5px;
    font-size: 12px;
    color: var(--muted);
  }

  .field input,
  .field textarea {
    padding: 10px 12px;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--field);
    color: var(--text);
    font: inherit;
    font-size: 14px;
    outline: none;
    resize: vertical;
  }

  .field input:focus,
  .field textarea:focus {
    border-color: var(--accent);
  }

  .editor-actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
  }

  .button {
    padding: 9px 16px;
    border: 0;
    border-radius: 10px;
    font: inherit;
    font-size: 13px;
    cursor: pointer;
  }

  .button.ghost {
    background: var(--field);
    color: var(--text);
  }

  .button.primary {
    background: var(--accent);
    color: #16101f;
    font-weight: 600;
  }

  .button:disabled {
    cursor: default;
    opacity: 0.6;
  }

  .device {
    margin: 12px 16px 0;
    color: var(--muted);
    font-size: 11px;
    text-align: center;
  }

  .error {
    margin: 12px 16px 0;
    color: var(--danger);
    font-size: 13px;
    text-align: center;
  }

  .notice {
    margin: 12px 16px 0;
    color: var(--accent);
    font-size: 12px;
    text-align: center;
  }
</style>
