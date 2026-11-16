/* ── Профиль GhostEcos: данные и контроллер ─────────
   Подключение одной строкой:
   <script src="/ui/ge-profile/ge-profile.js" data-ge-profile="orlova"></script>
   Скрипт сам подставит CSS, создаст контейнер после себя и загрузит профиль.
   Вариант с контейнером: <div data-ge-profile="orlova"></div> или <ge-profile user="orlova">.
   Хост не обязан знать про id и классы: снаружи только данные и CustomEvent. */
(function (global) {
  'use strict';

  const CONFIG = {
    apiBase: '/api/soc',
    soundBase: '/sound',
    tokenKey: 'gs_token',
    locale: 'ru-RU',
    timeout: 20000,
    statusLimit: 140,
    aboutLimit: 256,
    avatarLimit: 5 * 1024 * 1024,
  };

  // ── Общие помощники ──

  function esc(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function text(value) {
    if (value == null) return '';
    if (typeof value === 'object') return String(value.text || value.label || value.status || '');
    return String(value);
  }

  function initial(name) {
    const value = String(name || '').trim();
    return value ? value.charAt(0).toUpperCase() : '?';
  }

  function count(value) {
    if (value == null || value === '') return '—';
    const number = Number(value);
    if (!Number.isFinite(number) || number < 0) return '—';
    return String(Math.floor(number));
  }

  function imageSrc(value, depth) {
    if (typeof value === 'string') {
      const raw = value.trim();
      if (!raw) return '';
      if (/^data:image\//i.test(raw)) return raw;
      if (/^(https?:)?\/\//i.test(raw) || raw.charAt(0) === '/') return raw;
      return '';
    }
    if (!value || typeof value !== 'object' || (depth || 0) > 3) return '';
    const candidate = value.url || value.src || value.image_url || value.avatar_url ||
      value.banner_url || value.image;
    return typeof candidate === 'string' ? imageSrc(candidate) : imageSrc(candidate, (depth || 0) + 1);
  }

  function hexColor(value) {
    const raw = String(value || '').trim().replace(/^#/, '');
    return /^[0-9a-f]{6}$/i.test(raw) ? '#' + raw.toUpperCase() : '';
  }

  function profileDate(value) {
    const raw = text(value).trim();
    if (!raw) return null;
    const iso = /(?:z|[+-]\d{2}:?\d{2})$/i.test(raw) ? raw : raw.replace(' ', 'T') + 'Z';
    const date = new Date(iso);
    return Number.isNaN(date.getTime()) ? null : date;
  }

  function createdLabel(value) {
    const date = profileDate(value);
    if (!date) return '';
    const label = new Intl.DateTimeFormat(CONFIG.locale, {
      day: 'numeric', month: 'long', year: 'numeric',
    }).format(date).replace(' г.', '');
    return 'Присоединился ' + label;
  }

  // ── Авторизация и запросы ──

  function sessionToken() {
    try {
      const stored = String(localStorage.getItem(CONFIG.tokenKey) || '').trim();
      if (stored) return stored.replace(/^Bearer\s+/i, '');
    } catch (_) {}
    try {
      const match = document.cookie.match(/(?:^|;\s*)gs_token=([^;]*)/);
      if (match) {
        const cookieToken = decodeURIComponent(match[1]).trim().replace(/^Bearer\s+/i, '');
        if (cookieToken) return cookieToken;
      }
    } catch (_) {}
    try {
      const cached = JSON.parse(localStorage.getItem('gs_me') || 'null');
      const cachedToken = String(cached && cached.token || '').trim().replace(/^Bearer\s+/i, '');
      if (cachedToken) return cachedToken;
    } catch (_) {}
    return '';
  }

  function authHeaders(extra) {
    const headers = Object.assign({}, extra);
    const token = sessionToken();
    if (token) headers.Authorization = 'Bearer ' + token;
    return headers;
  }

  function apiPath(path) {
    if (/^https?:\/\//i.test(path)) return path;
    return CONFIG.apiBase + path;
  }

  /** Запрос к соцсети: JSON, таймаут, понятная ошибка. */
  async function request(path, options) {
    const opts = options || {};
    const method = opts.method || 'GET';
    const headers = authHeaders({ 'X-Ghost-Web': '1' });
    const controller = new AbortController();
    const relay = () => controller.abort();
    if (opts.signal) {
      if (opts.signal.aborted) controller.abort();
      else opts.signal.addEventListener('abort', relay, { once: true });
    }
    const timer = setTimeout(() => controller.abort(), opts.timeout || CONFIG.timeout);
    const init = { method, headers, credentials: 'include', signal: controller.signal };
    if (opts.body instanceof FormData) {
      init.body = opts.body;
    } else if (opts.body != null) {
      headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(opts.body);
    }
    try {
      const response = await fetch(apiPath(path), init);
      const raw = await response.text();
      let payload = null;
      if (raw) {
        try { payload = JSON.parse(raw); } catch (_) { payload = null; }
      }
      if (!response.ok) {
        const error = new Error((payload && (payload.detail || payload.message)) || raw ||
          'Ошибка ' + response.status);
        error.status = response.status;
        error.code = payload && payload.code;
        throw error;
      }
      return payload == null ? {} : payload;
    } catch (error) {
      if (error.name === 'AbortError' || controller.signal.aborted) {
        const timeoutError = new Error('Сервер не ответил за ' +
          Math.round((opts.timeout || CONFIG.timeout) / 1000) + ' с. Попробуй ещё раз.');
        timeoutError.timeout = true;
        throw timeoutError;
      }
      throw error;
    } finally {
      clearTimeout(timer);
      if (opts.signal) opts.signal.removeEventListener('abort', relay);
    }
  }

  // ── Нормализация ответа /prof ──

  function musicSource(track) {
    if (!track || typeof track !== 'object') return '';
    const source = String(track.source || track.provider || '').trim().toLowerCase();
    const slug = String(track.slug || '').trim();
    if (source === 'ghosou' && /^[A-Za-z0-9._-]{1,200}$/.test(slug)) {
      return CONFIG.soundBase + '/stream/' + encodeURIComponent(slug);
    }
    const candidates = [track.streamUrl, track.stream_url, track.audioUrl, track.audio_url, track.url];
    for (const candidate of candidates) {
      if (typeof candidate === 'string' && candidate.trim()) return candidate.trim();
    }
    return '';
  }

  function musicTracks(raw) {
    const value = raw.profile_music || raw.current_music || raw.music || raw.track;
    const list = Array.isArray(value) ? value : (value && typeof value === 'object' ? [value] : []);
    return list.map((track) => {
      const url = musicSource(track);
      if (!url) return null;
      return {
        title: text(track.name || track.title) || 'Без названия',
        artist: text(track.artist),
        cover: imageSrc(track.cover_url || track.coverUrl || track.cover),
        url,
        source: String(track.source || ''),
        raw: track,
      };
    }).filter(Boolean);
  }

  function musicPayload(track) {
    const payload = {
      source: track.source,
      track_id: track.track_id,
      slug: track.slug,
      url: track.url,
      name: track.name || track.title,
      artist: track.artist,
      album: track.album,
      cover_url: track.cover_url || track.coverUrl || null,
      duration_ms: track.duration_ms || 0,
    };
    let sourcePostId = Number(track.source_post_id) || 0;
    if (!sourcePostId) {
      const match = String(track.track_id || '').match(/^post:(\d+):/);
      if (match) sourcePostId = Number(match[1]) || 0;
    }
    if (sourcePostId > 0) payload.source_post_id = sourcePostId;
    return payload;
  }

  function bannerColor(raw) {
    const direct = hexColor(raw.color || raw.background || raw.background_color || raw.bg);
    if (direct) return direct;
    const colors = raw.colors;
    const list = Array.isArray(colors) ? colors
      : (colors && typeof colors === 'object' ? Object.values(colors) : []);
    for (const item of list) {
      const hex = hexColor(typeof item === 'string' ? item
        : item && (item.color || item.hex || item.value));
      if (hex) return hex;
    }
    return '';
  }

  function bannerData(raw) {
    if (!raw) return null;
    if (typeof raw === 'string') {
      const src = imageSrc(raw);
      return src ? { src } : { color: hexColor(raw) };
    }
    if (typeof raw !== 'object') return null;
    const src = imageSrc(raw);
    const color = bannerColor(raw);
    if (!src && !color) return null;
    return { src, color };
  }

  function mapPosts(list) {
    if (!Array.isArray(list)) return [];
    return list.map((post) => {
      const item = post || {};
      const media = Array.isArray(item.media) ? item.media : [];
      const first = media[0] || {};
      const type = String(first.type || item.media_type || '').toLowerCase();
      const src = imageSrc(first) || imageSrc(item.image_url || item.thumbnail_url ||
        item.preview_url || item.cover_url);
      if (src) return { id: item.id, src, video: type.indexOf('video') >= 0 };
      const body = text(item.text || item.caption || item.content).trim();
      return { id: item.id, text: body };
    });
  }

  /** Ответ /prof превращается в модель вида. */
  function normalize(raw) {
    const source = raw || {};
    const username = text(source.username || source.gc_username).trim().replace(/^@/, '');
    const name = text(source.display_name || source.name).trim() || username || 'Пользователь';
    const isMe = Boolean(source.is_me);

    const badges = [];
    const prefix = text(source.prefix || source.username_prefix).trim();
    if (prefix) badges.push({ text: prefix, tone: 'prefix' });
    if (source.is_admin) badges.push({ text: 'Администратор', tone: 'role' });
    else if (source.is_moderator) badges.push({ text: 'Модератор', tone: 'role' });
    const shields = Array.isArray(source.shields) ? source.shields
      : (Array.isArray(source.badges) ? source.badges : []);
    shields.slice(0, 4).forEach((shield) => {
      const label = typeof shield === 'string' ? shield
        : text(shield && (shield.name || shield.label || shield.title));
      if (label) badges.push({ text: label, tone: 'shield' });
    });

    const addedToday = Number(source.followers_added_today);
    const stats = [
      { id: 'following', label: 'Подписки', value: count(source.following_count) },
      {
        id: 'followers',
        label: 'Подписчики',
        value: count(source.followers_count),
        extra: addedToday > 0 ? '+' + addedToday + ' сегодня' : '',
      },
      { id: 'likes', label: 'Лайки', value: count(source.likes_received) },
    ];

    const meta = [];
    if (username) {
      meta.push({ icon: '@', value: '@' + username, label: 'Имя пользователя' });
    }
    const userId = source.id != null && source.id !== '' ? source.id : source.user_id;
    if (userId != null && userId !== '' && userId !== 0) {
      meta.push({ icon: '#', value: String(userId), label: 'ID пользователя' });
    }

    const reputationScore = source.reputation_score;
    const reputation = reputationScore == null ? null : {
      score: reputationScore,
      band: String(source.reputation_band || ''),
      label: 'Репутация ' + count(reputationScore),
    };

    const amFollowing = Boolean(source.am_following);
    const tracks = musicTracks(source);

    return {
      username,
      name,
      handle: username ? '@' + username : '',
      verified: Boolean(source.is_verified),
      isMe,
      variant: isMe ? 'own' : 'public',
      amFollowing,
      avatar: { src: imageSrc(source.avatar_url || source.avatar), letter: initial(name) },
      banner: bannerData(source.media_banner || source.banner || source.banner_config ||
        source.banner_settings),
      bio: text(source.about || source.bio || source.about_me || source.description).trim(),
      status: text(source.daily_status || source.status).trim(),
      badges,
      stats,
      reputation,
      created: createdLabel(source.created_at),
      meta,
      tracks,
      posts: mapPosts(source.posts),
      reposts: mapPosts(source.reposts),
    };
  }

  function looksRaw(data) {
    if (!data || typeof data !== 'object') return false;
    return 'is_me' in data || 'display_name' in data || 'followers_count' in data ||
      'am_following' in data || 'profile_music' in data;
  }

  // ── Иконки ──
  const ICONS = {
    pen: '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/>',
    share: '<path d="M12 16V4"/><path d="m7 9 5-5 5 5"/><path d="M4 16v3a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-3"/>',
    comment: '<path d="M21 11.5a7.5 7.5 0 0 1-10.9 6.7L4 20l1.8-5.1A7.5 7.5 0 1 1 21 11.5z"/>',
    follow: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M19 8v6M22 11h-6"/>',
    following: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="m17 11 2 2 4-4"/>',
    grid: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
    repeat: '<path d="m17 2 4 4-4 4"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><path d="m7 22-4-4 4-4"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/>',
    calendar: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M16 3v4M8 3v4M3 11h18"/>',
    music: '<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>',
    dots: '<circle cx="12" cy="5" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="12" cy="19" r="1.6"/>',
    play: '<path d="M8 5v14l11-7z" fill="currentColor" stroke="none"/>',
    pause: '<path d="M7 5h4v14H7zM13 5h4v14h-4z" fill="currentColor" stroke="none"/>',
    check: '<path d="m5 13 4 4L19 7"/>',
    close: '<path d="M18 6 6 18M6 6l12 12"/>',
    star: '<path d="m12 3 2.9 5.9 6.5.9-4.7 4.6 1.1 6.5-5.8-3-5.8 3 1.1-6.5L2.6 9.8l6.5-.9z"/>',
    trash: '<path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14"/>',
    camera: '<path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.2"/>',
    retry: '<path d="M3 12a9 9 0 0 1 15.5-6.2L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-15.5 6.2L3 16"/><path d="M3 21v-5h5"/>',
  };

  const STROKE = 'fill="none" stroke="currentColor" stroke-width="1.8" ' +
    'stroke-linecap="round" stroke-linejoin="round"';

  function icon(name) {
    const body = ICONS[name];
    return body ? `<svg viewBox="0 0 24 24" ${STROKE} aria-hidden="true">${body}</svg>` : '';
  }

  // ── Части разметки ──

  function avatarHtml(data, editable) {
    const src = data.avatar && data.avatar.src;
    const inner = src
      ? `<img src="${esc(src)}" alt="${esc(data.name || '')}" loading="lazy" decoding="async">`
      : esc((data.avatar && data.avatar.letter) || initial(data.name));
    if (editable) {
      return `<button type="button" class="ge-profile__avatar" data-ge-action="avatar"
        aria-label="Сменить аватар">${inner}</button>`;
    }
    return `<div class="ge-profile__avatar">${inner}</div>`;
  }

  function bannerHtml(data) {
    if (!data.banner) return '';
    const style = data.banner.color
      ? ` style="--ge-banner-color:${esc(data.banner.color)}"` : '';
    return `<div class="ge-profile__banner"${style}>${
      data.banner.src ? `<img src="${esc(data.banner.src)}" alt="" loading="eager" decoding="async">` : ''
    }</div>`;
  }

  function statusHtml(data, editable) {
    if (!data.status) return '';
    if (editable) {
      return `<button type="button" class="ge-profile__status" data-ge-action="status"
        title="Изменить статус"><span>${esc(data.status)}</span></button>`;
    }
    return `<div class="ge-profile__status"><span>${esc(data.status)}</span></div>`;
  }

  function badgesHtml(data) {
    const items = data.badges || [];
    if (!items.length) return '';
    const rows = items.map((badge) => {
      const tone = badge.tone ? ` ge-profile__badge--${esc(badge.tone)}` : '';
      return `<span class="ge-profile__badge${tone}">${esc(badge.text)}</span>`;
    }).join('');
    return `<div class="ge-profile__badges">${rows}</div>`;
  }

  function actionsHtml(data) {
    const items = data.actions || [];
    if (!items.length) return '';
    const rows = items.map((action) => {
      if (action.kind === 'icon') {
        return `<button type="button" class="ge-profile__icon-btn" data-ge-action="${esc(action.id)}"
          aria-label="${esc(action.label || '')}" title="${esc(action.label || '')}">${
          icon(action.icon)}</button>`;
      }
      const tone = action.tone ? ` ge-profile__button--${esc(action.tone)}` : '';
      const active = action.active ? ' is-active' : '';
      return `<button type="button" class="ge-profile__button${tone}${active}"
        data-ge-action="${esc(action.id)}"${action.pressed != null
          ? ` aria-pressed="${action.pressed ? 'true' : 'false'}"` : ''}>${
          action.icon ? icon(action.icon) : ''}<span>${esc(action.label || '')}</span></button>`;
    }).join('');
    return `<div class="ge-profile__actions">${rows}</div>`;
  }

  function actionsFor(data) {
    if (data.isMe) {
      return [
        { id: 'edit', label: 'Редактировать', icon: 'pen', tone: 'soft' },
        { id: 'share', label: 'Поделиться', icon: 'share', tone: 'soft' },
      ];
    }
    const follow = data.amFollowing
      ? { id: 'follow', label: 'Отписаться', tone: 'soft', active: true, pressed: true }
      : { id: 'follow', label: 'Подписаться', tone: 'primary', pressed: false };
    return [
      follow,
      { id: 'message', label: 'Написать', icon: 'comment', tone: 'soft' },
      { id: 'share', icon: 'share', kind: 'icon', label: 'Поделиться профилем' },
    ];
  }

  function statsHtml(data) {
    const items = data.stats || [];
    if (!items.length) return '';
    const rows = items.map((stat) => {
      const extra = stat.extra
        ? `<small class="ge-profile__stat-extra">${esc(stat.extra)}</small>` : '';
      return `<div class="ge-profile__stat" data-ge-stat="${esc(stat.id || '')}">
        <div class="ge-profile__stat-value">${esc(stat.value)}</div>
        <div class="ge-profile__stat-label">${esc(stat.label)}</div>${extra}
      </div>`;
    }).join('');
    return `<div class="ge-profile__stats">${rows}</div>`;
  }

  function musicHtml(data) {
    const music = data.music;
    if (!music) return '';
    const cover = music.cover
      ? `<img class="ge-profile__music-cover" src="${esc(music.cover)}" alt="" loading="lazy"
          decoding="async">`
      : `<span class="ge-profile__music-placeholder">${icon('music')}</span>`;
    const artist = music.artist
      ? `<small class="ge-profile__music-artist">${esc(music.artist)}</small>` : '';
    const playing = music.playing ? ' is-playing' : '';
    return `<div class="ge-profile__music${playing}">
      <button type="button" class="ge-profile__music-info" data-ge-action="music-open"
        aria-label="${esc(music.title || 'Музыка профиля')}">
        ${cover}
        <span class="ge-profile__music-copy">
          <strong class="ge-profile__music-title">${esc(music.title || '')}</strong>${artist}
        </span>
      </button>
      <button type="button" class="ge-profile__music-play" data-ge-action="music-toggle"
        aria-label="${music.playing ? 'Пауза' : 'Включить музыку профиля'}"
        aria-pressed="${music.playing ? 'true' : 'false'}">${
        icon(music.playing ? 'pause' : 'play')}</button>
    </div>`;
  }

  function metaHtml(data) {
    const items = data.meta || [];
    if (!items.length) return '';
    const rows = items.map((field) => `<div class="ge-profile__field">
        <span class="ge-profile__field-icon" aria-hidden="true">${esc(field.icon || '#')}</span>
        <span class="ge-profile__field-copy">
          <strong class="ge-profile__field-value">${esc(field.value)}</strong>
          <small class="ge-profile__field-label">${esc(field.label || '')}</small>
        </span>
      </div>`).join('');
    return `<div class="ge-profile__meta">${rows}<div class="ge-profile__divider"></div></div>`;
  }

  function tabsHtml(data, active) {
    const items = data.tabs || [{ id: 'posts', icon: 'grid', label: 'Посты' },
      { id: 'reposts', icon: 'repeat', label: 'Репосты' }];
    if (!items.length) return '';
    const rows = items.map((tab) => `<button type="button"
        class="ge-profile__tab${(active || 'posts') === tab.id ? ' is-active' : ''}"
        data-ge-tab="${esc(tab.id)}" role="tab"
        aria-selected="${(active || 'posts') === tab.id ? 'true' : 'false'}"
        aria-label="${esc(tab.label || tab.id)}" title="${esc(tab.label || tab.id)}">${
        icon(tab.icon || 'grid')}</button>`).join('');
    return `<div class="ge-profile__tabs" role="tablist">${rows}</div>`;
  }

  function postsHtml(data, active) {
    const items = (active === 'reposts' ? data.reposts : data.posts) || [];
    if (!items.length) {
      return `<div class="ge-profile__empty">${
        active === 'reposts' ? 'Репостов пока нет' : 'Публикаций пока нет'}</div>`;
    }
    const rows = items.map((post, index) => {
      if (post.text) {
        return `<button type="button" class="ge-profile__tile ge-profile__tile--text"
          data-ge-post="${index}"><span class="ge-profile__tile-text">${
          esc(post.text)}</span></button>`;
      }
      const media = post.video
        ? `<video src="${esc(post.src)}" muted playsinline preload="metadata"></video>`
        : `<img src="${esc(post.src)}" alt="" loading="lazy" decoding="async">`;
      return `<button type="button" class="ge-profile__tile" data-ge-post="${index}">${media}</button>`;
    }).join('');
    return `<div class="ge-profile__grid">${rows}</div>`;
  }

  function reputationHtml(data) {
    const reputation = data.reputation;
    if (!reputation) return '';
    const band = reputation.band ? ` ge-profile__reputation--${esc(reputation.band)}` : '';
    return `<div class="ge-profile__reputation${band}">${icon('star')}<span>${
      esc(reputation.label || ('Репутация ' + count(reputation.score)))}</span></div>`;
  }

  // ── Сборка вида ──

  function render(data) {
    const source = data || {};
    const active = source.activeTab || 'posts';
    const isPublic = source.variant === 'public' ||
      (source.variant == null && source.isMe === false);
    const modifiers = ['ge-profile', `ge-profile--${isPublic ? 'public' : 'own'}`];
    if (source.compact) modifiers.push('ge-profile--compact');
    if (source.surface) modifiers.push('ge-profile--surface');
    if (!source.banner) modifiers.push('ge-profile--no-banner');
    if (source.statusInline) modifiers.push('ge-profile--status-inline');

    const verified = source.verified
      ? `<span class="ge-profile__verified" title="Подтверждённый аккаунт">${icon('check')}</span>`
      : '';

    const identity = `<div class="ge-profile__identity">
        <div class="ge-profile__name-row">
          <div class="ge-profile__name">${esc(source.name || '')}${verified}</div>
        </div>
        ${badgesHtml(source)}
        ${source.handle ? `<div class="ge-profile__handle">${esc(source.handle)}</div>` : ''}
      </div>`;

    const created = source.created
      ? `<div class="ge-profile__created">${icon('calendar')}<span>${esc(source.created)}</span></div>`
      : '';

    const statusEdit = source.statusEdit
      ? `<button type="button" class="ge-profile__status-edit" data-ge-action="status">${
        esc(source.statusEdit)}</button>`
      : '';

    const body = `<div class="ge-profile__body">
        ${identity}
        ${actionsHtml(Object.assign({}, source, { actions: source.actions || actionsFor(source) }))}
        ${statsHtml(source)}
        ${source.bio ? `<div class="ge-profile__bio">${esc(source.bio)}</div>` : ''}
        ${created}
        ${musicHtml(source)}
        ${metaHtml(source)}
        ${reputationHtml(source)}
        ${statusEdit}
      </div>`;

    return `<div class="${modifiers.join(' ')}">
      <div class="ge-profile__card">
        ${bannerHtml(source)}
        ${avatarHtml(source, source.isMe)}
        ${statusHtml(source, source.isMe)}
        ${body}
      </div>
      ${tabsHtml(source, active)}
      ${postsHtml(source, active)}
    </div>`;
  }

  function skeletonHtml() {
    return `<div class="ge-profile ge-profile--loading" aria-busy="true" aria-label="Загрузка профиля">
      <div class="ge-profile__card">
        <div class="ge-profile__banner ge-profile__skeleton ge-profile__skeleton--banner"></div>
        <div class="ge-profile__avatar ge-profile__skeleton ge-profile__skeleton--avatar"></div>
        <div class="ge-profile__body">
          <div class="ge-profile__skeleton ge-profile__skeleton--line lg"></div>
          <div class="ge-profile__skeleton ge-profile__skeleton--line sm"></div>
          <div class="ge-profile__skeleton ge-profile__skeleton--stats"></div>
          <div class="ge-profile__skeleton ge-profile__skeleton--line"></div>
        </div>
      </div>
      <div class="ge-profile__skeleton ge-profile__skeleton--grid"></div>
    </div>`;
  }

  function errorHtml(message) {
    return `<div class="ge-profile ge-profile--error" role="alert">
      <div class="ge-profile__error">
        <strong>Не удалось загрузить профиль</strong>
        <span>${esc(message || 'Повтори попытку позже')}</span>
        <button type="button" class="ge-profile__button ge-profile__button--soft"
          data-ge-action="retry">${icon('retry')}<span>Повторить</span></button>
      </div>
    </div>`;
  }

  // ── События и мелочи интерфейса ──

  function emit(root, type, detail) {
    root.dispatchEvent(new CustomEvent(type, { detail: detail || {}, bubbles: true }));
  }

  let toastTimer = null;

  function toast(message) {
    if (!message) return;
    let node = document.querySelector('.ge-profile__toast');
    if (!node) {
      node = document.createElement('div');
      node.className = 'ge-profile__toast';
      node.setAttribute('role', 'status');
      document.body.appendChild(node);
    }
    node.textContent = message;
    node.classList.add('is-visible');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => node.classList.remove('is-visible'), 2400);
  }

  function sheet(html, onOpen) {
    const node = document.createElement('div');
    node.className = 'ge-profile ge-profile__sheet';
    node.innerHTML = `<div class="ge-profile__sheet-panel" role="dialog" aria-modal="true">${html}</div>`;
    document.body.appendChild(node);
    document.body.classList.add('ge-profile-sheet-open');
    const close = () => {
      node.remove();
      document.body.classList.remove('ge-profile-sheet-open');
      document.removeEventListener('keydown', onKey);
    };
    const onKey = (event) => {
      if (event.key === 'Escape') close();
    };
    document.addEventListener('keydown', onKey);
    node.addEventListener('mousedown', (event) => {
      if (event.target === node) close();
    });
    node.querySelectorAll('[data-ge-close]').forEach((button) => {
      button.addEventListener('click', close);
    });
    if (onOpen) onOpen(node, close);
    return { node, close };
  }

  function shareProfile(instance) {
    const data = instance.data || {};
    const url = instance.options.shareUrl
      ? instance.options.shareUrl(data.username)
      : location.href;
    const title = data.name || data.handle || 'Профиль';
    if (navigator.share) {
      navigator.share({ title, url }).catch(() => {});
      return;
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(url).then(
        () => toast('Ссылка скопирована'),
        () => toast(url),
      );
      return;
    }
    toast(url);
  }

  // ── Экземпляр профиля ──

  function create(root, options) {
    const opts = Object.assign({}, options);
    const offline = Boolean(opts.offline);
    const state = {
      raw: null,
      view: null,
      tracks: [],
      playing: false,
      playingIndex: 0,
      activeTab: 'posts',
      loading: false,
      error: null,
    };
    let unbind = null;
    let audio = null;
    let alive = true;

    function username() {
      if (opts.username) return opts.username;
      const view = state.view || {};
      const handle = String(view.handle || '').replace(/^@/, '');
      return view.username || handle || (state.raw && state.raw.username) || '';
    }

    function ensureAudio() {
      if (audio) return audio;
      audio = new Audio();
      audio.preload = 'none';
      audio.addEventListener('ended', () => {
        if (state.tracks.length > 1) {
          playMusic((state.playingIndex + 1) % state.tracks.length);
        } else {
          state.playing = false;
          draw();
        }
      });
      audio.addEventListener('error', () => {
        state.playing = false;
        draw();
        toast('Не удалось воспроизвести трек');
      });
      return audio;
    }

    function playMusic(index) {
      const track = state.tracks[index];
      if (!track) return;
      const player = ensureAudio();
      if (state.playing && state.playingIndex === index) {
        player.pause();
        state.playing = false;
        draw();
        return;
      }
      player.src = track.url;
      player.loop = state.tracks.length === 1;
      player.play().then(() => {
        state.playingIndex = index;
        state.playing = true;
        draw();
        emit(root, 'ge-profile:music', { track, index });
      }).catch(() => {
        state.playing = false;
        draw();
        toast('Браузер заблокировал воспроизведение');
      });
    }

    function viewModel() {
      const base = state.view || {};
      const index = Math.min(Math.max(state.playingIndex, 0), Math.max(state.tracks.length - 1, 0));
      const track = state.tracks[index];
      return Object.assign({}, base, {
        activeTab: state.activeTab,
        statusEdit: base.isMe && !base.status ? 'Добавить статус' : '',
        music: track ? Object.assign({}, track, { playing: state.playing }) : (base.music || null),
      });
    }

    function paint() {
      if (!alive) return;
      if (unbind) { unbind(); unbind = null; }
      if (state.loading) {
        root.innerHTML = skeletonHtml();
        return;
      }
      if (state.error) {
        root.innerHTML = errorHtml(state.error.message);
        bind();
        return;
      }
      if (!state.view) return;
      root.innerHTML = render(viewModel());
      bind();
    }

    function draw() {
      paint();
    }

    function setRaw(raw) {
      state.raw = raw;
      state.view = normalize(raw);
      state.tracks = state.view.tracks.slice();
      state.playing = false;
      state.playingIndex = 0;
    }

    async function load() {
      const name = username();
      if (offline) {
        state.loading = false;
        draw();
        return;
      }
      if (!name) {
        state.error = new Error('Не указан пользователь');
        state.loading = false;
        paint();
        return;
      }
      state.loading = true;
      state.error = null;
      paint();
      const encoded = encodeURIComponent(name);
      try {
        const profile = await request('/prof/' + encoded, { signal: opts.signal });
        if (!alive) return;
        setRaw(profile);
        emit(root, 'ge-profile:ready', { profile });
      } catch (error) {
        if (!alive) return;
        state.error = error;
        emit(root, 'ge-profile:error', { error });
      } finally {
        if (!alive) return;
        state.loading = false;
        draw();
      }
    }

    function setFollowing(next) {
      if (!state.view) return;
      state.view.amFollowing = next;
      const followers = (state.view.stats || []).find((stat) => stat.id === 'followers');
      if (followers) {
        const current = Number(String(followers.value).replace(/\s/g, ''));
        if (Number.isFinite(current)) followers.value = count(current + (next ? 1 : -1));
      }
      draw();
      emit(root, 'ge-profile:follow', { username: username(), following: next });
    }

    async function toggleFollow(button) {
      const name = username();
      if (!name) return;
      const next = !(state.view && state.view.amFollowing);
      if (offline) { setFollowing(next); return; }
      if (button) button.disabled = true;
      try {
        await request('/follow/' + encodeURIComponent(name), {
          method: next ? 'POST' : 'DELETE',
        });
        if (!alive) return;
        setFollowing(next);
      } catch (error) {
        toast(error.message || 'Не удалось изменить подписку');
        if (button) button.disabled = false;
      }
    }

    async function saveAvatar(file) {
      if (!file) return;
      if (offline) { toast('Демо: загрузка файлов отключена'); return; }
      if (file.size > CONFIG.avatarLimit) {
        toast('Файл больше 5 МБ');
        return;
      }
      const body = new FormData();
      body.append('file', file);
      try {
        const result = await request('/me/avatar', { method: 'POST', body });
        if (!alive) return;
        const src = imageSrc(result.avatar_url);
        if (state.view) state.view.avatar = { src, letter: initial(state.view.name) };
        if (state.raw) state.raw.avatar_url = result.avatar_url;
        draw();
        toast('Аватар обновлён');
        emit(root, 'ge-profile:profile', { profile: state.raw });
      } catch (error) {
        toast(error.message || 'Не удалось загрузить аватар');
      }
    }

    async function removeAvatar() {
      if (offline) { toast('Демо: загрузка файлов отключена'); return; }
      try {
        await request('/me/avatar', { method: 'DELETE' });
        if (!alive) return;
        if (state.view) state.view.avatar = { src: '', letter: initial(state.view.name) };
        if (state.raw) state.raw.avatar_url = null;
        draw();
        toast('Аватар убран');
        emit(root, 'ge-profile:profile', { profile: state.raw });
      } catch (error) {
        toast(error.message || 'Не удалось убрать аватар');
      }
    }

    function openEditor() {
      const data = state.raw || {};
      const current = state.view || {};
      const form = sheet(`<header class="ge-profile__sheet-head">
          <strong>Редактировать профиль</strong>
          <button type="button" class="ge-profile__sheet-close" data-ge-close
            aria-label="Закрыть">${icon('close')}</button>
        </header>
        <div class="ge-profile__sheet-body">
          <div class="ge-profile__sheet-avatar">
            <span class="ge-profile__sheet-avatar-view">${
              current.avatar && current.avatar.src
                ? `<img src="${esc(current.avatar.src)}" alt="">`
                : esc(initial(current.name))
            }</span>
            <span class="ge-profile__sheet-avatar-actions">
              <label class="ge-profile__button ge-profile__button--soft">
                ${icon('camera')}<span>Сменить</span>
                <input type="file" accept="image/jpeg,image/png,image/webp" hidden data-ge-avatar>
              </label>
              ${current.avatar && current.avatar.src
                ? `<button type="button" class="ge-profile__button ge-profile__button--danger"
                    data-ge-avatar-remove>Убрать</button>` : ''}
            </span>
          </div>
          <label class="ge-profile__field-edit">
            <span>Имя</span>
            <input type="text" maxlength="64" data-ge-field="display_name"
              value="${esc(data.display_name || current.name || '')}">
          </label>
          <label class="ge-profile__field-edit">
            <span>Имя пользователя</span>
            <input type="text" maxlength="32" data-ge-field="username"
              value="${esc(data.username || current.username || '')}" autocapitalize="none">
          </label>
          <label class="ge-profile__field-edit">
            <span>О себе</span>
            <textarea rows="3" maxlength="${CONFIG.aboutLimit}" data-ge-field="about">${
              esc(data.about || current.bio || '')}</textarea>
          </label>
          <p class="ge-profile__sheet-error" data-ge-error role="alert"></p>
        </div>
        <footer class="ge-profile__sheet-foot">
          <button type="button" class="ge-profile__button ge-profile__button--primary"
            data-ge-save>Сохранить</button>
        </footer>`, (node, close) => {
        const errorLine = node.querySelector('[data-ge-error]');
        const save = node.querySelector('[data-ge-save]');
        const fileInput = node.querySelector('[data-ge-avatar]');

        if (fileInput) {
          fileInput.addEventListener('change', () => {
            const file = fileInput.files && fileInput.files[0];
            fileInput.value = '';
            if (file) saveAvatar(file).then(() => close());
          });
        }
        node.querySelectorAll('[data-ge-avatar-remove]').forEach((button) => {
          button.addEventListener('click', () => removeAvatar().then(() => close()));
        });

        save.addEventListener('click', async () => {
          const body = {};
          node.querySelectorAll('[data-ge-field]').forEach((field) => {
            const key = field.dataset.geField;
            const value = field.value.trim();
            const previous = String(data[key] || '').trim();
            if (value !== previous) body[key] = value;
          });
          if (!Object.keys(body).length) { close(); return; }
          if (body.username != null && !/^[A-Za-z0-9_.]{3,32}$/.test(body.username)) {
            errorLine.textContent = 'Имя пользователя: от 3 до 32 символов, латиница, цифры, _ и .';
            return;
          }
          save.disabled = true;
          save.textContent = 'Сохраняю';
          try {
            if (offline) {
              if (state.view) {
                Object.assign(state.view, body);
                state.view.name = body.display_name || state.view.name;
                state.view.username = body.username || state.view.username;
                state.view.handle = state.view.username ? '@' + state.view.username : '';
                if (body.about != null) state.view.bio = body.about;
                state.view.avatar = {
                  src: state.view.avatar && state.view.avatar.src,
                  letter: initial(state.view.name),
                };
              }
              draw();
              close();
              toast('Профиль обновлён (демо)');
              emit(root, 'ge-profile:profile', { profile: body });
              return;
            }
            const result = await request('/me/profile', { method: 'PATCH', body });
            if (!alive) return;
            if (state.raw) {
              ['display_name', 'username', 'about'].forEach((key) => {
                if (result[key] != null) state.raw[key] = result[key];
              });
            }
            setRaw(state.raw || result);
            state.activeTab = 'posts';
            draw();
            close();
            toast('Профиль обновлён');
            emit(root, 'ge-profile:profile', { profile: state.raw });
          } catch (error) {
            errorLine.textContent = error.message || 'Не удалось сохранить профиль';
          } finally {
            save.disabled = false;
            save.textContent = 'Сохранить';
          }
        });
      });
      return form;
    }

    function openStatus() {
      const current = (state.view && state.view.status) || '';
      return sheet(`<header class="ge-profile__sheet-head">
          <strong>Статус на сегодня</strong>
          <button type="button" class="ge-profile__sheet-close" data-ge-close
            aria-label="Закрыть">${icon('close')}</button>
        </header>
        <div class="ge-profile__sheet-body">
          <p class="ge-profile__sheet-hint">Одна строка, как день. Видна всем в профиле
            и сбрасывается через 24 часа.</p>
          <label class="ge-profile__field-edit">
            <textarea rows="2" maxlength="${CONFIG.statusLimit}" data-ge-status>${
              esc(current)}</textarea>
          </label>
          <small class="ge-profile__sheet-counter" data-ge-counter>${
            current.length} / ${CONFIG.statusLimit}</small>
          <p class="ge-profile__sheet-error" data-ge-error role="alert"></p>
        </div>
        <footer class="ge-profile__sheet-foot">
          <button type="button" class="ge-profile__button ge-profile__button--primary"
            data-ge-status-save>Опубликовать</button>
        </footer>`, (node, close) => {
        const field = node.querySelector('[data-ge-status]');
        const counter = node.querySelector('[data-ge-counter]');
        const errorLine = node.querySelector('[data-ge-error]');
        const save = node.querySelector('[data-ge-status-save]');
        field.addEventListener('input', () => {
          counter.textContent = field.value.length + ' / ' + CONFIG.statusLimit;
          save.disabled = !field.value.trim();
        });
        save.disabled = !field.value.trim();
        save.addEventListener('click', async () => {
          const value = field.value.trim();
          if (!value) return;
          save.disabled = true;
          try {
            if (offline) {
              if (state.view) state.view.status = value;
              draw();
              close();
              toast('Статус обновлён (демо)');
              emit(root, 'ge-profile:status', { text: value });
              return;
            }
            await request('/status/set', { method: 'POST', body: { text: value } });
            if (!alive) return;
            if (state.view) state.view.status = value;
            draw();
            close();
            toast('Статус обновлён');
            emit(root, 'ge-profile:status', { text: value });
          } catch (error) {
            errorLine.textContent = error.message || 'Не удалось сохранить статус';
            save.disabled = false;
          }
        });
      });
    }

    async function persistTracks(tracks) {
      if (offline) {
        state.tracks = tracks.slice();
        if (state.view) state.view.tracks = state.tracks;
        draw();
        toast(tracks.length ? 'Музыка обновлена (демо)' : 'Музыка убрана (демо)');
        emit(root, 'ge-profile:music', { tracks });
        return;
      }
      const body = tracks.length
        ? {
          profile_music: tracks.map((track) => musicPayload(
            Object.assign({}, track.raw || track, { url: track.url }))),
        }
        : { music_clear: true };
      try {
        const result = await request('/me/profile', { method: 'PATCH', body });
        if (!alive) return;
        const list = Array.isArray(result.profile_music) ? result.profile_music : [];
        if (state.raw) state.raw.profile_music = list;
        state.tracks = musicTracks({ profile_music: list });
        if (state.view) state.view.tracks = state.tracks;
        state.playing = false;
        if (audio) audio.pause();
        draw();
        toast(tracks.length ? 'Музыка профиля обновлена' : 'Музыка убрана');
        emit(root, 'ge-profile:music', { tracks: list });
      } catch (error) {
        toast(error.message || 'Не удалось обновить музыку');
      }
    }

    function openMusic() {
      if (!state.tracks.length) return;
      const rows = state.tracks.map((track, index) => `<li class="ge-profile__track">
          <button type="button" class="ge-profile__track-play" data-ge-track="${index}"
            aria-label="Включить ${esc(track.title)}">${
            icon(state.playing && state.playingIndex === index ? 'pause' : 'play')}</button>
          <span class="ge-profile__track-copy">
            <strong>${esc(track.title)}</strong>
            <small>${esc(track.artist || '')}</small>
          </span>
          ${state.view && state.view.isMe
            ? `<button type="button" class="ge-profile__track-remove" data-ge-track-remove="${index}"
                aria-label="Убрать из профиля">${icon('trash')}</button>` : ''}
        </li>`).join('');
      return sheet(`<header class="ge-profile__sheet-head">
          <strong>Музыка профиля</strong>
          <button type="button" class="ge-profile__sheet-close" data-ge-close
            aria-label="Закрыть">${icon('close')}</button>
        </header>
        <ul class="ge-profile__sheet-body ge-profile__tracks">${rows}</ul>`, (node, close) => {
        node.querySelectorAll('[data-ge-track]').forEach((button) => {
          button.addEventListener('click', () => {
            playMusic(Number(button.dataset.geTrack));
            close();
          });
        });
        node.querySelectorAll('[data-ge-track-remove]').forEach((button) => {
          button.addEventListener('click', () => {
            const next = state.tracks.slice();
            next.splice(Number(button.dataset.geTrackRemove), 1);
            close();
            persistTracks(next);
          });
        });
      });
    }

    function bind() {
      const onClick = (event) => {
        const tab = event.target.closest('[data-ge-tab]');
        if (tab && root.contains(tab)) {
          state.activeTab = tab.dataset.geTab;
          root.querySelectorAll('[data-ge-tab]').forEach((node) => {
            const active = node === tab;
            node.classList.toggle('is-active', active);
            node.setAttribute('aria-selected', active ? 'true' : 'false');
          });
          const grid = root.querySelector('.ge-profile__grid, .ge-profile__empty');
          if (grid && state.view) {
            const html = postsHtml(viewModel(), state.activeTab);
            const holder = document.createElement('div');
            holder.innerHTML = html;
            grid.replaceWith(holder.firstElementChild);
          }
          emit(root, 'ge-profile:tab', { tab: tab.dataset.geTab });
          return;
        }
        const post = event.target.closest('[data-ge-post]');
        if (post && root.contains(post)) {
          emit(root, 'ge-profile:post', {
            index: Number(post.dataset.gePost),
            tab: state.activeTab,
            post: ((state.activeTab === 'reposts' ? state.view.reposts : state.view.posts) || [])
              .filter(Boolean)[Number(post.dataset.gePost)] || null,
          });
          return;
        }
        const action = event.target.closest('[data-ge-action]');
        if (!action || !root.contains(action)) return;
        const name = action.dataset.geAction;
        emit(root, 'ge-profile:action', { action: name, data: state.view });
        if (name === 'retry') load();
        else if (name === 'follow') toggleFollow(action);
        else if (name === 'share') shareProfile(instance);
        else if (name === 'edit' || name === 'avatar') openEditor();
        else if (name === 'status') openStatus();
        else if (name === 'music-open') openMusic();
        else if (name === 'music-toggle') playMusic(state.playing ? state.playingIndex : 0);
      };
      root.addEventListener('click', onClick);
      unbind = () => root.removeEventListener('click', onClick);
    }

    const instance = {
      root,
      options: opts,
      get username() { return username(); },
      get data() { return state.view; },
      get raw() { return state.raw; },
      get tracks() { return state.tracks.slice(); },
      load,
      refresh: load,
      openEditor,
      openStatus,
      openMusic,
      /** Ответ API или объект с его полями. */
      update(next) {
        setRaw(next || {});
        state.loading = false;
        state.error = null;
        state.activeTab = 'posts';
        draw();
        return instance.data;
      },
      /** Готовая модель вида без обращения к сети. */
      renderView(next) {
        const view = Object.assign({}, next || {});
        state.raw = looksRaw(view) ? view : null;
        state.view = view;
        state.tracks = Array.isArray(view.tracks) ? view.tracks.slice()
          : (view.music && view.music.url ? [view.music] : []);
        state.playing = false;
        state.playingIndex = 0;
        state.loading = false;
        state.error = null;
        state.activeTab = view.activeTab || 'posts';
        draw();
        return state.view;
      },
      destroy() {
        alive = false;
        if (unbind) unbind();
        unbind = null;
        if (audio) {
          audio.pause();
          audio.removeAttribute('src');
          audio = null;
        }
        root.innerHTML = '';
      },
    };

    return instance;
  }

  // ── Подключение ──

  function injectStyles(src) {
    if (!src || document.querySelector('link[data-ge-profile-css]')) return;
    const href = src.replace(/\.js(\?|#|$)/, '.css$1');
    if (href === src) return;
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = href;
    link.setAttribute('data-ge-profile-css', '');
    document.head.appendChild(link);
  }

  function readData(element) {
    const json = element.getAttribute('data-ge-profile-json') ||
      element.getAttribute('data-ge-json');
    if (!json) return null;
    try { return JSON.parse(json); } catch (_) { return null; }
  }

  function mountElement(element) {
    if (!element || element._geProfile || element.tagName === 'SCRIPT') return null;
    const value = String(element.getAttribute('data-ge-profile') || '').trim();
    let data = readData(element);
    let name = value;
    if (!data && value.charAt(0) === '{') {
      try { data = JSON.parse(value); name = ''; } catch (_) {}
    }
    if (!data && !name) return null;
    element._geProfile = create(element, {
      username: name,
      data,
      apiBase: element.getAttribute('data-ge-profile-api') || undefined,
      shareUrl: undefined,
    });
    if (data) element._geProfile.update(data);
    else element._geProfile.load();
    return element._geProfile;
  }

  function scan(scope) {
    const parent = scope && scope.querySelectorAll ? scope : document;
    if (parent.matches && parent.matches('[data-ge-profile]')) mountElement(parent);
    parent.querySelectorAll('[data-ge-profile]').forEach(mountElement);
  }

  function autoBoot() {
    const script = document.currentScript;
    if (script) injectStyles(script.src);
    const name = script && (script.dataset.geProfile || script.dataset.user);
    if (script && script.dataset.api) CONFIG.apiBase = script.dataset.api;
    if (name && script.tagName === 'SCRIPT') {
      const host = document.createElement('div');
      host.className = 'ge-profile-host';
      script.parentNode.insertBefore(host, script.nextSibling);
      const instance = create(host, {
        username: name,
        apiBase: script.dataset.api,
        shareUrl: script.dataset.shareUrl ? (username) => script.dataset.shareUrl + username : undefined,
      });
      host._geProfile = instance;
      instance.load();
    }
    scan(document);
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', () => scan(document));
    }
    if (global.MutationObserver) {
      const observer = new MutationObserver((records) => {
        records.forEach((record) => {
          record.addedNodes.forEach((node) => {
            if (node.nodeType === 1) scan(node);
          });
        });
      });
      observer.observe(document.documentElement, { childList: true, subtree: true });
    }
  }

  function defineElement() {
    if (!global.customElements || global.customElements.get('ge-profile')) return;
    global.customElements.define('ge-profile', class extends HTMLElement {
      connectedCallback() {
        if (this._geProfile) return;
        const name = this.getAttribute('user') || this.getAttribute('username') || '';
        if (!name) return;
        this._geProfile = create(this, {
          username: name,
          apiBase: this.getAttribute('api') || undefined,
        });
        this._geProfile.load();
      }
      disconnectedCallback() {
        if (this._geProfile) {
          this._geProfile.destroy();
          this._geProfile = null;
        }
      }
    });
  }

  // ── Публичный интерфейс ──

  const GeProfile = {
    render,
    normalize,
    request,
    configure(patch) {
      Object.assign(CONFIG, patch || {});
    },
    get config() { return Object.assign({}, CONFIG); },

    /** Статичный рендер: принимает и ответ API, и готовую модель вида. */
    mount(root, data, options) {
      const instance = create(root, Object.assign({ offline: true }, options));
      if (looksRaw(data)) instance.update(data);
      else instance.renderView(data || {});
      return instance;
    },

    /** Подключение к соцсети: грузит /prof и включает действия. */
    connect(root, options) {
      const instance = create(root, options || {});
      if (!options || !options.data) instance.load();
      return instance;
    },

    scan,
  };

  if (typeof module === 'object' && module.exports) {
    module.exports = GeProfile;
  } else {
    global.GeProfile = GeProfile;
  }

  defineElement();
  autoBoot();
}(typeof window !== 'undefined' ? window : this));
