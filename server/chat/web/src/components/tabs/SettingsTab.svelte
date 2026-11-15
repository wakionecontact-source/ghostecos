<script lang="ts">
  import { onMount } from 'svelte';
  import { chatApi, type DeviceRow, type PrivacyFlags } from '../../lib/api/chat';
  import type { MeProfile } from '../../lib/api/me';
  import type { WebSession } from '../../lib/auth/session';
  import { getThread, listThreads } from '../../lib/chat/messages';
  import { idbClear, STORE_MESSAGES } from '../../lib/storage/db';
  import { ACCENTS, applyPrefs, loadPrefs, savePrefs, type AccentName, type WebPrefs } from '../../lib/ui/prefs';

  interface Props {
    session: WebSession;
    me: MeProfile | null;
    onlogout: () => void;
  }

  let { session, me, onlogout }: Props = $props();

  const api = $derived(chatApi(session.token));
  const appVersion = 'GhostChat Web';

  let prefs = $state<WebPrefs>(loadPrefs());
  let privacy = $state<PrivacyFlags>({});
  let devices = $state<DeviceRow[]>([]);
  let currentId = $state<number | null>(null);
  let busy = $state('');
  let notice = $state('');
  let error = $state('');

  onMount(() => {
    applyPrefs(prefs);
    void loadPrivacy();
    void loadDevices();
  });

  function flash(text: string): void {
    notice = text;
    window.setTimeout(() => {
      if (notice === text) notice = '';
    }, 2600);
  }

  async function loadPrivacy(): Promise<void> {
    try {
      privacy = await api.privacy();
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось загрузить приватность';
    }
  }

  async function savePrivacy(patch: PrivacyFlags): Promise<void> {
    privacy = { ...privacy, ...patch };
    busy = 'privacy';
    error = '';
    try {
      privacy = await api.setPrivacy(patch);
      flash('Сохранено');
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Настройка не сохранена';
    } finally {
      busy = '';
    }
  }

  async function loadDevices(): Promise<void> {
    try {
      const result = await api.devices();
      devices = result.devices;
      currentId = result.current_id;
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось загрузить устройства';
    }
  }

  async function rename(device: DeviceRow): Promise<void> {
    const name = window.prompt('Название устройства', device.device_name || device.platform || '');
    if (!name || !name.trim()) return;
    busy = `device-${device.id}`;
    try {
      await api.renameDevice(device.id, name.trim());
      await loadDevices();
      flash('Название обновлено');
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось переименовать';
    } finally {
      busy = '';
    }
  }

  async function revoke(device: DeviceRow): Promise<void> {
    if (!window.confirm(`Отозвать устройство «${device.device_name || device.platform || device.id}»?`)) return;
    busy = `device-${device.id}`;
    try {
      await api.revokeDevice(device.id);
      await loadDevices();
      flash('Устройство отозвано');
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось отозвать';
    } finally {
      busy = '';
    }
  }

  function pickAccent(name: AccentName): void {
    prefs = { ...prefs, accent: name };
    savePrefs(prefs);
    applyPrefs(prefs);
  }

  async function toggleNotifications(): Promise<void> {
    if (prefs.notifications) {
      prefs = { ...prefs, notifications: false };
      savePrefs(prefs);
      return;
    }
    if (!('Notification' in window)) {
      error = 'Браузер не поддерживает уведомления';
      return;
    }
    const permission = await Notification.requestPermission();
    if (permission !== 'granted') {
      error = 'Уведомления запрещены в настройках браузера';
      return;
    }
    prefs = { ...prefs, notifications: true };
    savePrefs(prefs);
    flash('Уведомления включены');
  }

  async function exportHistory(): Promise<void> {
    busy = 'export';
    try {
      const threads = await listThreads();
      const dump = {
        exported_at: new Date().toISOString(),
        account: session.username,
        threads: await Promise.all(
          threads.map(async (thread) => ({
            peer: thread.peer,
            messages: (await getThread(thread.peer)).map((message) => ({
              ts: message.ts,
              mine: message.mine,
              text: message.text,
              file: message.file
                ? { name: message.file.file_name, mime: message.file.mime, size: message.file.size }
                : undefined,
            })),
          })),
        ),
      };
      const blob = new Blob([JSON.stringify(dump, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = `ghostchat-${session.username}-${Date.now()}.json`;
      link.click();
      window.setTimeout(() => URL.revokeObjectURL(url), 10_000);
      flash('Экспорт сохранён');
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Экспорт не удался';
    } finally {
      busy = '';
    }
  }

  async function clearLocal(): Promise<void> {
    if (!window.confirm('Удалить локальную историю на этом устройстве? Восстановить её будет нельзя.')) {
      return;
    }
    busy = 'clear';
    try {
      await idbClear(STORE_MESSAGES);
      localStorage.removeItem('gc.web.readmarks');
      flash('Локальная история очищена');
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Очистка не удалась';
    } finally {
      busy = '';
    }
  }

  const visibilityOptions = [
    { value: 'all', title: 'Все' },
    { value: 'contacts', title: 'Контакты' },
    { value: 'nobody', title: 'Никто' },
  ];

  const lastSeen = (value: number | null): string => {
    if (!value) return 'не заходило';
    const date = new Date(value * 1000);
    return date.toLocaleDateString('ru-RU', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
  };
</script>

<div class="tab">
  {#if error}<p class="banner error">{error}</p>{/if}
  {#if notice}<p class="banner ok">{notice}</p>{/if}

  <section class="group">
    <p class="caption">Аккаунт</p>
    <div class="card">
      <div class="row static">
        <span class="label">Имя</span>
        <span class="value">{me?.display_name || session.username}</span>
      </div>
      <div class="row static">
        <span class="label">Логин</span>
        <span class="value">@{session.username}</span>
      </div>
      <div class="row static">
        <span class="label">Устройство</span>
        <span class="value">#{session.deviceId}</span>
      </div>
    </div>
  </section>

  <section class="group">
    <p class="caption">Приватность</p>
    <div class="card">
      <button class="row" onclick={() => savePrivacy({ show_online: !privacy.show_online })}>
        <span class="label">Показывать «в сети»</span>
        <span class="switch" class:on={!!privacy.show_online} role="presentation"></span>
      </button>
      <button class="row" onclick={() => savePrivacy({ send_read_receipts: !privacy.send_read_receipts })}>
        <span class="label">Отправлять отчёты о прочтении</span>
        <span class="switch" class:on={!!privacy.send_read_receipts} role="presentation"></span>
      </button>
      <div class="row column">
        <span class="label">Кто может писать</span>
        <span class="segmented">
          {#each visibilityOptions as option (option.value)}
            <button
              class="segment"
              class:active={privacy.message_privacy === option.value}
              onclick={() => savePrivacy({ message_privacy: option.value })}
            >{option.title}</button>
          {/each}
        </span>
      </div>
      <div class="row column">
        <span class="label">Кто видит профиль</span>
        <span class="segmented">
          {#each visibilityOptions as option (option.value)}
            <button
              class="segment"
              class:active={privacy.display_name_visibility === option.value}
              onclick={() => savePrivacy({ display_name_visibility: option.value })}
            >{option.title}</button>
          {/each}
        </span>
      </div>
      {#if busy === 'privacy'}<p class="row-note">Сохраняем…</p>{/if}
    </div>
  </section>

  <section class="group">
    <p class="caption">Уведомления</p>
    <div class="card">
      <button class="row" onclick={toggleNotifications}>
        <span class="label">Уведомления браузера</span>
        <span class="switch" class:on={prefs.notifications} role="presentation"></span>
      </button>
      <p class="note">
        Приходят, когда вкладка неактивна. Текст сообщения не показывается — только имя отправителя.
      </p>
    </div>
  </section>

  <section class="group">
    <p class="caption">Оформление</p>
    <div class="card">
      <div class="row column">
        <span class="label">Акцент</span>
        <span class="accents">
          {#each Object.entries(ACCENTS) as [name, palette] (name)}
            <button
              class="accent"
              class:active={prefs.accent === name}
              style={`--swatch: ${palette.accent}`}
              title={palette.title}
              aria-label={palette.title}
              onclick={() => pickAccent(name as AccentName)}
            ></button>
          {/each}
        </span>
      </div>
    </div>
  </section>

  <section class="group">
    <p class="caption">Устройства</p>
    <div class="card">
      {#if devices.length === 0}
        <p class="note">Список пуст.</p>
      {:else}
        {#each devices as device (device.id)}
          <div class="row device">
            <span class="device-info">
              <span class="label">
                {device.device_name || device.platform || `Устройство ${device.id}`}
                {#if device.id === currentId}<span class="badge">текущее</span>{/if}
                {#if Number(device.is_blocked)}<span class="badge danger">отозвано</span>{/if}
              </span>
              <span class="value small">
                {device.platform || 'web'} · {lastSeen(device.last_seen)}
              </span>
            </span>
            <span class="device-actions">
              <button class="mini" onclick={() => rename(device)} disabled={busy === `device-${device.id}`}>
                Имя
              </button>
              <button
                class="mini danger"
                onclick={() => revoke(device)}
                disabled={device.id === currentId || busy === `device-${device.id}`}
              >Отозвать</button>
            </span>
          </div>
        {/each}
      {/if}
    </div>
  </section>

  <section class="group">
    <p class="caption">Данные и память</p>
    <div class="card">
      <button class="row" onclick={exportHistory} disabled={busy === 'export'}>
        <span class="label">Экспорт переписки</span>
        <span class="chev">{busy === 'export' ? '…' : '›'}</span>
      </button>
      <button class="row" onclick={clearLocal} disabled={busy === 'clear'}>
        <span class="label danger">Очистить локальную историю</span>
        <span class="chev">{busy === 'clear' ? '…' : '›'}</span>
      </button>
    </div>
  </section>

  <section class="group">
    <p class="caption">Безопасность</p>
    <div class="card">
      <p class="note">
        Ключ шифрования создаётся на этом устройстве и хранится только здесь. Сервер видит сообщения
        как зашифрованный контейнер.
      </p>
      <button class="row" onclick={onlogout}>
        <span class="label danger">Забыть устройство и выйти</span>
      </button>
    </div>
  </section>

  <section class="group">
    <p class="caption">О приложении</p>
    <div class="card">
      <div class="row static">
        <span class="label">Клиент</span>
        <span class="value">{appVersion}</span>
      </div>
      <a class="row" href="/v2/social" target="_blank" rel="noreferrer">
        <span class="label">GhostSocial</span>
        <span class="chev">›</span>
      </a>
    </div>
  </section>
</div>

<style>
  .tab {
    height: 100%;
    width: 100%;
    max-width: 720px;
    margin: 0 auto;
    overflow-y: auto;
    padding-bottom: 28px;
  }

  .banner {
    position: sticky;
    top: 0;
    z-index: 2;
    margin: 0 12px 4px;
    padding: 9px 12px;
    border-radius: 10px;
    font-size: 12px;
  }

  .banner.error {
    background: rgba(240, 120, 120, 0.14);
    color: var(--danger);
  }

  .banner.ok {
    background: rgba(179, 154, 244, 0.16);
    color: var(--accent);
  }

  .group {
    margin-top: 16px;
  }

  .caption {
    margin: 0 0 6px;
    padding: 0 18px;
    color: var(--muted);
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.04em;
    text-transform: uppercase;
  }

  .card {
    margin: 0 12px;
    border-radius: 14px;
    overflow: hidden;
    background: var(--card);
  }

  .row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    width: 100%;
    padding: 13px 16px;
    border: 0;
    background: transparent;
    color: inherit;
    font: inherit;
    font-size: 15px;
    text-align: left;
    cursor: pointer;
  }

  .row.column {
    flex-direction: column;
    align-items: stretch;
    gap: 8px;
    cursor: default;
  }

  .row + .row,
  .row + .note,
  .note + .row {
    border-top: 1px solid var(--border);
  }

  .row.static {
    cursor: default;
  }

  .row:disabled {
    cursor: default;
    opacity: 0.6;
  }

  .label {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: none;
  }

  .label.danger {
    color: var(--danger);
  }

  .value {
    overflow: hidden;
    color: var(--muted);
    font-size: 13px;
    text-align: right;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .value.small {
    font-size: 11px;
  }

  .chev {
    color: var(--muted);
    font-size: 18px;
  }

  .switch {
    position: relative;
    flex: none;
    width: 42px;
    height: 24px;
    border-radius: 999px;
    background: var(--field);
    transition: background 0.16s ease;
  }

  .switch::after {
    content: '';
    position: absolute;
    top: 3px;
    left: 3px;
    width: 18px;
    height: 18px;
    border-radius: 50%;
    background: #d8d5e2;
    transition: transform 0.16s ease, background 0.16s ease;
  }

  .switch.on {
    background: var(--accent);
  }

  .switch.on::after {
    transform: translateX(18px);
    background: #16101f;
  }

  .segmented {
    display: flex;
    gap: 4px;
    padding: 3px;
    border-radius: 10px;
    background: var(--field);
  }

  .segment {
    flex: 1;
    padding: 7px 8px;
    border: 0;
    border-radius: 8px;
    background: transparent;
    color: var(--muted);
    font: inherit;
    font-size: 13px;
    cursor: pointer;
  }

  .segment.active {
    background: var(--row-active);
    color: var(--text);
  }

  .accents {
    display: flex;
    gap: 10px;
  }

  .accent {
    width: 28px;
    height: 28px;
    border: 2px solid transparent;
    border-radius: 50%;
    background: var(--swatch);
    cursor: pointer;
  }

  .accent.active {
    border-color: var(--text);
  }

  .note {
    margin: 0;
    padding: 12px 16px;
    color: var(--muted);
    font-size: 12px;
    line-height: 1.5;
  }

  .row-note {
    margin: 0;
    padding: 0 16px 12px;
    color: var(--muted);
    font-size: 11px;
  }

  .device {
    cursor: default;
  }

  .device-info {
    display: grid;
    gap: 3px;
    min-width: 0;
  }

  .device-actions {
    display: flex;
    flex: none;
    gap: 6px;
  }

  .mini {
    padding: 6px 9px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: transparent;
    color: var(--text);
    font-size: 11px;
    cursor: pointer;
  }

  .mini.danger {
    color: var(--danger);
  }

  .mini:disabled {
    cursor: default;
    opacity: 0.45;
  }

  .badge {
    padding: 2px 6px;
    border-radius: 6px;
    background: rgba(179, 154, 244, 0.18);
    color: var(--accent);
    font-size: 10px;
    font-weight: 600;
  }

  .badge.danger {
    background: rgba(240, 120, 120, 0.16);
    color: var(--danger);
  }

  a.row {
    text-decoration: none;
  }

  a.row:hover,
  button.row:hover:not(:disabled) {
    background: var(--row-hover);
  }
</style>
