<script lang="ts">
  import { onMount } from 'svelte';
  import { chatApi, type DeviceRow, type PrivacyFlags } from '../../lib/api/chat';
  import { updateProfile, uploadAvatar, type MeProfile } from '../../lib/api/me';
  import type { WebSession } from '../../lib/auth/session';
  import { getThread, listThreads } from '../../lib/chat/messages';
  import { idbClear, STORE_MESSAGES } from '../../lib/storage/db';
  import { ACCENTS, applyPrefs, loadPrefs, savePrefs, type AccentName, type WebPrefs } from '../../lib/ui/prefs';

  interface Props {
    session: WebSession;
    me: MeProfile | null;
    onlogout: () => void;
    onrefresh?: () => void;
  }

  let { session, me, onlogout, onrefresh }: Props = $props();

  type View = 'main' | 'profile' | 'devices' | 'keys' | 'privacy' | 'notifications' | 'appearance' | 'data' | 'about';

  const api = $derived(chatApi(session.token));
  const appVersion = 'GhostChat Web';

  let view = $state<View>('main');
  let filter = $state('');
  let prefs = $state<WebPrefs>(loadPrefs());
  let privacy = $state<PrivacyFlags>({});
  let devices = $state<DeviceRow[]>([]);
  let currentId = $state<number | null>(null);
  let busy = $state('');
  let notice = $state('');
  let error = $state('');

  let editName = $state('');
  let editAbout = $state('');
  let profileLoaded = $state(false);
  let avatarInput = $state<HTMLInputElement | null>(null);

  onMount(() => {
    applyPrefs(prefs);
    void loadPrivacy();
    void loadDevices();
  });

  $effect(() => {
    if (me && !profileLoaded) {
      editName = me.display_name || '';
      editAbout = me.about || '';
      profileLoaded = true;
    }
  });

  const initial = $derived((me?.display_name || session.username || '?').trim().charAt(0).toUpperCase());

  function open(next: View): void {
    view = next;
    filter = '';
    error = '';
    notice = '';
  }

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

  async function saveProfile(): Promise<void> {
    busy = 'profile';
    error = '';
    try {
      await updateProfile(session.token, {
        display_name: editName.trim(),
        about: editAbout.trim(),
      });
      onrefresh?.();
      flash('Профиль сохранён');
      view = 'main';
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Профиль не сохранён';
    } finally {
      busy = '';
    }
  }

  async function pickAvatar(event: Event): Promise<void> {
    const input = event.target as HTMLInputElement;
    const file = input.files?.[0] ?? null;
    input.value = '';
    if (!file) return;
    busy = 'avatar';
    error = '';
    try {
      await uploadAvatar(session.token, file);
      onrefresh?.();
      flash('Аватар обновлён');
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Аватар не загружен';
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

  interface Item {
    id: View;
    icon: string;
    title: string;
    subtitle: string;
  }

  interface Category {
    caption: string;
    items: Item[];
  }

  const categories = $derived<Category[]>([
    {
      caption: 'Аккаунт',
      items: [
        { id: 'profile', icon: '◍', title: 'Профиль', subtitle: 'Имя, юзернейм, о себе' },
        { id: 'devices', icon: '▤', title: 'Устройства', subtitle: 'Сессии и доверенные устройства' },
        { id: 'keys', icon: '⛨', title: 'Ключи шифрования', subtitle: 'Ключ на устройстве и копия на сервере' },
      ],
    },
    {
      caption: 'Оформление',
      items: [{ id: 'appearance', icon: '◐', title: 'Внешний вид', subtitle: 'Тема оформления' }],
    },
    {
      caption: 'Безопасность',
      items: [
        { id: 'privacy', icon: '⛊', title: 'Приватность', subtitle: 'Видимость в сети и статус прочтения' },
        { id: 'notifications', icon: '◔', title: 'Уведомления', subtitle: 'Push-уведомления браузера' },
      ],
    },
    {
      caption: 'Данные',
      items: [{ id: 'data', icon: '▦', title: 'Хранилище', subtitle: 'Экспорт и локальная история' }],
    },
    {
      caption: 'Прочее',
      items: [{ id: 'about', icon: 'ⓘ', title: 'О приложении', subtitle: 'Версия, помощь' }],
    },
  ]);

  const query = $derived(filter.trim().toLowerCase());

  const visible = $derived(
    categories
      .map((category) => ({
        ...category,
        items: query
          ? category.items.filter((item) =>
              `${item.title} ${item.subtitle} ${category.caption}`.toLowerCase().includes(query),
            )
          : category.items,
      }))
      .filter((category) => category.items.length > 0),
  );

  const found = $derived(visible.reduce((total, category) => total + category.items.length, 0));

  const lastSeen = (value: number | null): string => {
    if (!value) return 'не заходило';
    const date = new Date(value * 1000);
    return date.toLocaleDateString('ru-RU', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
  };
</script>

{#snippet banner()}
  {#if error}<p class="banner error">{error}</p>{/if}
  {#if notice}<p class="banner ok">{notice}</p>{/if}
{/snippet}

{#snippet back(title: string)}
  <div class="bar">
    <button class="back" onclick={() => open('main')} aria-label="Назад">‹</button>
    <span class="bar-title">{title}</span>
  </div>
{/snippet}

<div class="tab">
  {@render banner()}

  {#if view === 'main'}
    <div class="card profile-card">
      <p class="profile-title">Мой профиль</p>
      <div class="banner-strip">
        <span class="avatar big">
          {#if me?.avatar_url}
            <img src={me.avatar_url} alt="" />
          {:else}
            {initial}
          {/if}
        </span>
      </div>
      <button class="prow" onclick={() => open('profile')}>
        <span class="picon">◍</span>
        <span class="pdata">
          <span class="plabel">Имя</span>
          <span class="pvalue">{me?.display_name || session.username}</span>
        </span>
        <span class="pencil">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
            <path d="M4 20h4l10-10-4-4L4 16v4z" />
            <path d="M13.5 6.5l4 4" />
          </svg>
        </span>
      </button>
      <button class="prow" onclick={() => open('profile')}>
        <span class="picon">@</span>
        <span class="pdata">
          <span class="plabel">Username</span>
          <span class="pvalue">@{session.username}</span>
        </span>
        <span class="pencil">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
            <path d="M4 20h4l10-10-4-4L4 16v4z" />
            <path d="M13.5 6.5l4 4" />
          </svg>
        </span>
      </button>
      <div class="pdivider"></div>
      <button class="prow" onclick={() => open('profile')}>
        <span class="picon">ⓘ</span>
        <span class="pdata">
          <span class="plabel">О себе</span>
          <span class="pvalue">{me?.about || 'Не указано'}</span>
        </span>
        <span class="pencil">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
            <path d="M4 20h4l10-10-4-4L4 16v4z" />
            <path d="M13.5 6.5l4 4" />
          </svg>
        </span>
      </button>
      <button class="prow" onclick={() => flash('Пароль меняется в приложении')}>
        <span class="picon">⌂</span>
        <span class="pdata">
          <span class="plabel">Пароль</span>
          <span class="pvalue">••••••••</span>
        </span>
        <span class="pencil">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">
            <path d="M4 20h4l10-10-4-4L4 16v4z" />
            <path d="M13.5 6.5l4 4" />
          </svg>
        </span>
      </button>
      <div class="pdivider"></div>
      <div class="prow static">
        <span class="picon">#</span>
        <span class="pdata">
          <span class="plabel">ID</span>
          <span class="pvalue">{me?.id ?? session.username}</span>
        </span>
      </div>
    </div>

    <div class="search">
      <input bind:value={filter} placeholder="Найти настройку" />
      {#if filter}
        <button class="clear" onclick={() => (filter = '')} aria-label="Очистить">✕</button>
      {/if}
    </div>

    {#if found === 0}
      <div class="card empty">
        <span class="empty-icon">⌕</span>
        <span class="empty-title">Ничего не найдено</span>
        <span class="empty-hint">Попробуй другое слово: «сеть», «ключи», «устройства».</span>
      </div>
    {:else}
      {#each visible as category (category.caption)}
        <section class="group">
          <p class="caption">{category.caption}</p>
          <div class="card">
            {#each category.items as item (item.id)}
              <button class="row" onclick={() => open(item.id)}>
                <span class="icon">{item.icon}</span>
                <span class="text">
                  <span class="row-title">{item.title}</span>
                  <span class="row-sub">{item.subtitle}</span>
                </span>
                <span class="chev">›</span>
              </button>
            {/each}
          </div>
        </section>
      {/each}
    {/if}

    <section class="group">
      <div class="card">
        <button class="row" onclick={onlogout}>
          <span class="icon danger">⏻</span>
          <span class="text"><span class="row-title danger">Выйти из аккаунта</span></span>
        </button>
      </div>
    </section>
  {:else if view === 'profile'}
    {@render back('Профиль')}
    <div class="card">
      <div class="field avatar-field">
        <span class="field-label">Аватар</span>
        <div class="avatar-row">
          <span class="avatar big">
            {#if me?.avatar_url}
              <img src={me.avatar_url} alt="" />
            {:else}
              {initial}
            {/if}
          </span>
          <button class="mini" onclick={() => avatarInput?.click()} disabled={busy === 'avatar'}>
            {busy === 'avatar' ? 'Загрузка…' : 'Сменить'}
          </button>
          <input
            bind:this={avatarInput}
            type="file"
            accept="image/jpeg,image/png,image/webp"
            hidden
            onchange={pickAvatar}
          />
        </div>
      </div>
      <div class="field">
        <span class="field-label">Имя</span>
        <input bind:value={editName} maxlength="40" placeholder="Как тебя видно в чатах" />
      </div>
      <div class="field">
        <span class="field-label">Юзернейм</span>
        <span class="value">@{session.username}</span>
        <span class="hint">Смена юзернейма — в приложении.</span>
      </div>
      <div class="field">
        <span class="field-label">О себе</span>
        <textarea bind:value={editAbout} maxlength="200" rows="3" placeholder="Коротко о себе"></textarea>
      </div>
      <div class="field">
        <span class="field-label">ID</span>
        <span class="value">{me?.id ?? '—'}</span>
      </div>
    </div>
    <button class="primary" onclick={saveProfile} disabled={busy === 'profile'}>
      {busy === 'profile' ? 'Сохраняем…' : 'Сохранить'}
    </button>
  {:else if view === 'devices'}
    {@render back('Устройства')}
    <div class="card">
      {#if devices.length === 0}
        <p class="note">Список пуст.</p>
      {:else}
        {#each devices as device (device.id)}
          <div class="row device">
            <span class="device-info">
              <span class="row-title">
                {device.device_name || device.platform || `Устройство ${device.id}`}
                {#if device.id === currentId}<span class="badge">текущее</span>{/if}
                {#if Number(device.is_blocked)}<span class="badge danger">отозвано</span>{/if}
              </span>
              <span class="row-sub">{device.platform || 'web'} · {lastSeen(device.last_seen)}</span>
            </span>
            <span class="device-actions">
              <button class="mini" onclick={() => rename(device)} disabled={busy === `device-${device.id}`}>Имя</button>
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
  {:else if view === 'keys'}
    {@render back('Ключи шифрования')}
    <div class="card">
      <p class="note">
        Ключ создаётся в этом браузере и хранится только здесь. Сервер видит сообщения как
        зашифрованный контейнер и не может их прочитать.
      </p>
      <div class="row static">
        <span class="text"><span class="row-title">Устройство</span></span>
        <span class="value">#{session.deviceId}</span>
      </div>
      <div class="row static">
        <span class="text"><span class="row-title">Аккаунт</span></span>
        <span class="value">@{session.username}</span>
      </div>
    </div>
    <p class="hint pad">
      Копия ключа на сервер и seed-фраза — на экране разблокировки; там же можно переиздать ключ.
    </p>
  {:else if view === 'privacy'}
    {@render back('Приватность')}
    <div class="card">
      <button class="row" onclick={() => savePrivacy({ show_online: !privacy.show_online })}>
        <span class="text"><span class="row-title">Показывать «в сети»</span></span>
        <span class="switch" class:on={!!privacy.show_online} role="presentation"></span>
      </button>
      <button class="row" onclick={() => savePrivacy({ send_read_receipts: !privacy.send_read_receipts })}>
        <span class="text"><span class="row-title">Отправлять отчёты о прочтении</span></span>
        <span class="switch" class:on={!!privacy.send_read_receipts} role="presentation"></span>
      </button>
      <div class="row column">
        <span class="row-title">Кто может писать</span>
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
        <span class="row-title">Кто видит профиль</span>
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
  {:else if view === 'notifications'}
    {@render back('Уведомления')}
    <div class="card">
      <button class="row" onclick={toggleNotifications}>
        <span class="text"><span class="row-title">Уведомления браузера</span></span>
        <span class="switch" class:on={prefs.notifications} role="presentation"></span>
      </button>
      <p class="note">
        Приходят, когда вкладка неактивна. Текст сообщения не показывается — только имя отправителя.
      </p>
    </div>
  {:else if view === 'appearance'}
    {@render back('Внешний вид')}
    <div class="card">
      <div class="row column">
        <span class="row-title">Акцент</span>
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
  {:else if view === 'data'}
    {@render back('Хранилище')}
    <div class="card">
      <button class="row" onclick={exportHistory} disabled={busy === 'export'}>
        <span class="text">
          <span class="row-title">Экспорт переписки</span>
          <span class="row-sub">Все чаты в один файл</span>
        </span>
        <span class="chev">{busy === 'export' ? '…' : '›'}</span>
      </button>
      <button class="row" onclick={clearLocal} disabled={busy === 'clear'}>
        <span class="text">
          <span class="row-title danger">Очистить локальную историю</span>
          <span class="row-sub">На этом устройстве</span>
        </span>
        <span class="chev">{busy === 'clear' ? '…' : '›'}</span>
      </button>
    </div>
    <p class="hint pad">История хранится в этом браузере; на сервере — только зашифрованные конверты.</p>
  {:else if view === 'about'}
    {@render back('О приложении')}
    <div class="card">
      <div class="row static">
        <span class="text"><span class="row-title">Клиент</span></span>
        <span class="value">{appVersion}</span>
      </div>
      <a class="row" href="/v2/social" target="_blank" rel="noreferrer">
        <span class="icon">◎</span>
        <span class="text">
          <span class="row-title">GhostSocial</span>
          <span class="row-sub">Соцсеть без алгоритмической ленты</span>
        </span>
        <span class="chev">›</span>
      </a>
    </div>
  {/if}
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

  .avatar {
    display: grid;
    place-items: center;
    flex: none;
    width: 56px;
    height: 56px;
    overflow: hidden;
    border-radius: 50%;
    background: linear-gradient(140deg, var(--accent), var(--accent-deep, #6d4fd0));
    color: #16101f;
    font-size: 22px;
    font-weight: 700;
  }

  .avatar.big {
    width: 72px;
    height: 72px;
    font-size: 28px;
  }

  .avatar img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }

  .profile-card {
    margin: 12px;
    padding: 16px 14px 12px;
    background: var(--card);
  }

  .profile-title {
    margin: 0 0 14px;
    font-size: 17px;
    font-weight: 800;
  }

  /* Полоса баннера как в приложении: аватар стоит слева и свисает с неё. */
  .banner-strip {
    display: flex;
    align-items: flex-end;
    height: 76px;
    padding-left: 4px;
    border-radius: 14px;
    background: linear-gradient(120deg, rgba(109, 79, 208, 0.55), rgba(179, 154, 244, 0.3));
  }

  .banner-strip .avatar {
    transform: translateY(18px);
    border: 3px solid var(--card);
  }

  .prow {
    display: flex;
    align-items: center;
    gap: 9px;
    width: 100%;
    padding: 11px 2px;
    border: 0;
    background: transparent;
    color: inherit;
    font: inherit;
    text-align: left;
    cursor: pointer;
  }

  .prow.static {
    cursor: default;
  }

  .picon {
    width: 18px;
    flex: none;
    color: var(--accent);
    text-align: center;
    font-size: 14px;
  }

  .pdata {
    display: grid;
    gap: 2px;
    min-width: 0;
    flex: 1 1 auto;
  }

  .plabel {
    color: var(--muted);
    font-size: 11px;
  }

  .pvalue {
    overflow: hidden;
    font-size: 14px;
    font-weight: 600;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .pencil {
    flex: none;
    width: 32px;
    height: 32px;
    display: grid;
    place-items: center;
    border-radius: 50%;
    color: var(--text);
  }

  .pencil svg {
    width: 16px;
    height: 16px;
  }

  /* Аватар свисает с баннера — отодвигаем первую строку, чтобы он её не задевал. */
  .banner-strip + .prow {
    margin-top: 10px;
  }

  .prow:hover .pencil {
    background: var(--row-hover);
  }

  .pdivider {
    height: 1px;
    margin: 4px 0;
    background: var(--border);
  }

  .search {
    position: relative;
    margin: 4px 12px 0;
  }

  .search input {
    width: 100%;
    padding: 13px 38px 13px 16px;
    border: 1px solid var(--border);
    border-radius: 12px;
    background: var(--field);
    color: var(--text);
    font: inherit;
    font-size: 14px;
  }

  .clear {
    position: absolute;
    top: 50%;
    right: 10px;
    transform: translateY(-50%);
    border: 0;
    background: transparent;
    color: var(--muted);
    font-size: 14px;
    cursor: pointer;
  }

  .bar {
    display: flex;
    align-items: center;
    gap: 6px;
    margin: 0 0 10px;
    padding: 6px 10px;
  }

  .back {
    width: 34px;
    height: 34px;
    border: 0;
    border-radius: 10px;
    background: transparent;
    color: var(--accent);
    font-size: 24px;
    line-height: 1;
    cursor: pointer;
  }

  .bar-title {
    font-size: 16px;
    font-weight: 600;
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

  .card.empty {
    display: grid;
    justify-items: center;
    gap: 6px;
    margin-top: 16px;
    padding: 22px 16px;
    text-align: center;
  }

  .empty-icon {
    color: var(--accent);
    font-size: 26px;
  }

  .empty-title {
    font-weight: 700;
  }

  .empty-hint {
    color: var(--muted);
    font-size: 12px;
  }

  .row {
    display: flex;
    align-items: center;
    gap: 12px;
    width: 100%;
    padding: 13px 16px;
    border: 0;
    background: transparent;
    color: inherit;
    font: inherit;
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
  .note + .row,
  .field + .field {
    border-top: 1px solid var(--border);
  }

  .row.static {
    cursor: default;
  }

  .row:disabled {
    cursor: default;
    opacity: 0.6;
  }

  .text {
    display: grid;
    gap: 2px;
    min-width: 0;
    flex: 1 1 auto;
  }

  .row-title {
    font-size: 15px;
  }

  .row-title.danger,
  .danger {
    color: var(--danger);
  }

  .row-sub {
    overflow: hidden;
    color: var(--muted);
    font-size: 12px;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .icon {
    width: 22px;
    flex: none;
    color: var(--muted);
    text-align: center;
    font-size: 15px;
  }

  .value {
    overflow: hidden;
    color: var(--muted);
    font-size: 13px;
    text-align: right;
    white-space: nowrap;
    text-overflow: ellipsis;
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

  .field {
    display: grid;
    gap: 6px;
    padding: 12px 16px;
  }

  .field-label {
    color: var(--muted);
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.04em;
    text-transform: uppercase;
  }

  .avatar-field {
    gap: 10px;
  }

  .avatar-row {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .field input,
  .field textarea {
    width: 100%;
    padding: 10px 12px;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: var(--field);
    color: var(--text);
    font: inherit;
    font-size: 14px;
    resize: vertical;
  }

  .hint {
    color: var(--muted);
    font-size: 11px;
    line-height: 1.5;
  }

  .hint.pad {
    margin: 10px 0 0;
    padding: 0 18px;
  }

  .primary {
    display: block;
    width: calc(100% - 24px);
    margin: 12px;
    padding: 13px 16px;
    border: 0;
    border-radius: 12px;
    background: var(--accent);
    color: #16101f;
    font: inherit;
    font-weight: 600;
    cursor: pointer;
  }

  .primary:disabled {
    opacity: 0.6;
    cursor: default;
  }

  .device {
    cursor: default;
  }

  .device-info {
    display: grid;
    gap: 3px;
    min-width: 0;
    flex: 1 1 auto;
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
