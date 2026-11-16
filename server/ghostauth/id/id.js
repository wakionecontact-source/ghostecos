/* GhostID · /id — кабинет сохранённых аккаунтов в дизайне GhostSocial v2.
   Опирается на общий стор /auth/ghostid-accounts.js (ключ gs_accounts_v1)
   и существующие API GhostSocial: /api/soc/me, /me/profile, /me/avatar, /wallet. */
(function () {
  'use strict';

  var store = window.GhostIDAccounts;
  if (!store) return;

  var ME = '/api/soc/me';
  var PROFILE = '/api/soc/me/profile';
  var AVATAR = '/api/soc/me/avatar';
  var WALLET = '/api/soc/wallet';
  var AUTH_URL = '/v2/auth?return=%2Fid';
  var MAX_UPLOAD = 5 * 1024 * 1024;
  var ALLOWED_TYPES = ['image/jpeg', 'image/png', 'image/webp'];
  var HINT_TIMEOUT = 5000;
  var RU_MONTHS = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
    'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];

  var els = {
    empty: document.querySelector('[data-empty]'),
    active: document.querySelector('[data-active]'),
    bannerImage: document.querySelector('[data-banner-image]'),
    avatar: document.querySelector('[data-avatar]'),
    name: document.querySelector('[data-name]'),
    verified: document.querySelector('[data-verified]'),
    handle: document.querySelector('[data-handle]'),
    following: document.querySelector('[data-stat-following]'),
    followers: document.querySelector('[data-stat-followers]'),
    likes: document.querySelector('[data-stat-likes]'),
    about: document.querySelector('[data-about]'),
    joined: document.querySelector('[data-joined]'),
    joinedText: document.querySelector('[data-joined-text]'),
    music: document.querySelector('[data-music]'),
    musicCover: document.querySelector('[data-music-cover]'),
    musicTitle: document.querySelector('[data-music-title]'),
    musicArtist: document.querySelector('[data-music-artist]'),
    musicTime: document.querySelector('[data-music-time]'),
    musicFill: document.querySelector('[data-music-fill]'),
    musicOpen: document.querySelector('[data-music-open]'),
    musicPlay: document.querySelector('[data-music-play]'),
    audio: document.querySelector('[data-music-audio]'),
    musicSheet: document.querySelector('[data-music-sheet]'),
    musicSheetClose: document.querySelector('[data-music-close]'),
    musicCount: document.querySelector('[data-music-count]'),
    trackList: document.querySelector('[data-track-list]'),
    activeId: document.querySelector('[data-active-id]'),
    activeBalance: document.querySelector('[data-active-balance]'),
    editActive: document.querySelector('[data-edit-active]'),
    logoutActive: document.querySelector('[data-logout-active]'),
    listWrap: document.querySelector('[data-list-wrap]'),
    list: document.querySelector('[data-list]'),
    listTitle: document.querySelector('[data-list-title]'),
    count: document.querySelector('[data-count]'),
    add: document.querySelector('[data-add]'),
    hint: document.querySelector('[data-hint]'),
    editor: document.querySelector('[data-editor]'),
    editorClose: document.querySelector('[data-close]'),
    editorCancel: document.querySelector('[data-cancel]'),
    editorSave: document.querySelector('[data-save]'),
    editorAccount: document.querySelector('[data-editor-account]'),
    editorAvatar: document.querySelector('[data-editor-avatar]'),
    avatarInput: document.querySelector('[data-avatar-input]'),
    avatarRemove: document.querySelector('[data-avatar-remove]'),
    editorName: document.querySelector('[data-editor] [name=display_name]'),
    editorAbout: document.querySelector('[data-editor] [name=about]'),
    editorStatus: document.querySelector('[data-editor-status]')
  };

  var state = {
    details: {},
    loading: {},
    editingId: '',
    editorAvatar: '',
    saving: false,
    busyAvatar: false,
    tracks: [],
    trackIndex: 0
  };
  var hintTimer = 0;

  // ── Общие помощники ──────────────────────────────

  function safeUrl(raw) {
    if (!raw) return '';
    try {
      var url = new URL(String(raw), location.origin);
      return url.protocol === 'https:' || url.origin === location.origin ? url.href : '';
    } catch (_) { return ''; }
  }

  function initial(profile) {
    var name = String(profile.display_name || profile.username || 'G').trim();
    return name.charAt(0).toUpperCase() || 'G';
  }

  function paintAvatar(node, profile) {
    if (!node) return;
    var url = safeUrl(profile.avatar_url);
    node.textContent = url ? '' : initial(profile);
    node.style.backgroundImage = url ? 'url("' + url.replace(/"/g, '%22') + '")' : '';
  }

  /** Дата регистрации приходит в UTC — показываем по Москве, как в соцсети. */
  function joinedLabel(raw) {
    var text = String(raw || '').trim();
    if (!text) return '';
    var iso = text.indexOf('T') === -1 ? text.replace(' ', 'T') + 'Z' : text;
    var date = new Date(iso);
    if (isNaN(date.getTime())) return '';
    var parts = new Intl.DateTimeFormat('ru-RU', {
      day: 'numeric', month: 'numeric', year: 'numeric', timeZone: 'Europe/Moscow'
    }).formatToParts(date);
    var map = {};
    for (var i = 0; i < parts.length; i++) map[parts[i].type] = parts[i].value;
    return 'Присоединился ' + map.day + ' ' + RU_MONTHS[Number(map.month) - 1] + ' ' + map.year;
  }

  function formatCount(value) {
    var number = Number(value);
    return isFinite(number) ? String(number) : '0';
  }

  /** Кошелёк отдаёт число, но старые ответы могли прийти объектом. */
  function normalBalance(raw) {
    var value = raw;
    if (value && typeof value === 'object') {
      value = value.balance != null ? value.balance : (value.amount != null ? value.amount : null);
    }
    var number = Number(value);
    return value == null || !isFinite(number) ? null : number;
  }

  function formatTime(seconds) {
    var total = Math.max(0, Math.round(Number(seconds) || 0));
    var minutes = Math.floor(total / 60);
    var rest = total % 60;
    return minutes + ':' + (rest < 10 ? '0' : '') + rest;
  }

  function apiHeaders(token) {
    return { Accept: 'application/json', Authorization: 'Bearer ' + token, 'X-Ghost-Web': '1' };
  }

  async function readError(response, fallback) {
    var payload = null;
    try { payload = await response.json(); } catch (_) {}
    var detail = payload && (payload.detail || payload.message);
    if (typeof detail === 'string' && detail.trim()) return detail;
    if (response.status === 401) return 'Сессия истекла. Войди заново.';
    if (response.status === 403) return 'Сервер отклонил действие.';
    return fallback;
  }

  function hint(message, ok) {
    if (!els.hint) return;
    els.hint.textContent = message || '';
    els.hint.classList.toggle('is-ok', Boolean(ok));
    clearTimeout(hintTimer);
    if (message) {
      hintTimer = setTimeout(function () {
        els.hint.textContent = '';
        els.hint.classList.remove('is-ok');
      }, HINT_TIMEOUT);
    }
  }

  function editorStatus(message, ok) {
    if (!els.editorStatus) return;
    els.editorStatus.textContent = message || '';
    els.editorStatus.classList.toggle('is-ok', Boolean(ok));
  }

  function cachedMe() {
    try { return JSON.parse(localStorage.getItem('gs_me') || 'null') || {}; } catch (_) { return {}; }
  }

  function clearSession() {
    try {
      localStorage.removeItem('gs_token');
      localStorage.removeItem('gs_me');
    } catch (_) {}
    document.cookie = 'gs_token=; Path=/; Max-Age=0; SameSite=Lax' +
      (location.protocol === 'https:' ? '; Secure' : '');
  }

  function entryById(id) {
    var key = String(id || '');
    var list = store.list();
    for (var i = 0; i < list.length; i++) {
      if (list[i].profile.id === key) return list[i];
    }
    return null;
  }

  /** Текущий активный аккаунт; при отсутствии записи в сторе — из кэша gs_me. */
  function activeEntry() {
    var token = store.currentToken();
    if (!token) return null;
    var list = store.list();
    for (var i = 0; i < list.length; i++) {
      if (list[i].token === token) return list[i];
    }
    var me = cachedMe();
    var id = me && (me.id || me.user_id);
    if (!id) return null;
    return {
      token: token,
      savedAt: 0,
      profile: {
        id: String(id),
        username: String(me.username || '').replace(/^@/, ''),
        display_name: String(me.display_name || ''),
        avatar_url: String(me.avatar_url || ''),
        is_guest: Boolean(me.is_guest)
      }
    };
  }

  // ── Баннер и плеер ───────────────────────────────

  function paintBanner(details) {
    var media = details.mediaBanner && details.mediaBanner.url ? details.mediaBanner.url : '';
    var src = safeUrl(media);
    if (!els.bannerImage) return;
    if (!src) {
      els.bannerImage.hidden = true;
      els.bannerImage.removeAttribute('src');
      return;
    }
    els.bannerImage.onerror = function () { els.bannerImage.hidden = true; };
    els.bannerImage.src = src;
    els.bannerImage.hidden = false;
  }

  /** Цвет из #rgb/#rrggbb в «r, g, b» для rgba(). */
  function hexRgb(raw) {
    var hex = String(raw || '').trim().replace('#', '');
    if (hex.length === 3) hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2];
    if (!/^[0-9a-f]{6}$/i.test(hex)) return '255, 255, 255';
    return parseInt(hex.slice(0, 2), 16) + ', ' +
      parseInt(hex.slice(2, 4), 16) + ', ' +
      parseInt(hex.slice(4, 6), 16);
  }

  /** Фон баннера: свечения из banner_config, иначе простой градиент. */
  function bannerBackground(banner) {
    var colors = banner && Array.isArray(banner.colors) ? banner.colors : [];
    var bg = banner && banner.background_color ? String(banner.background_color) : '#141018';
    var lights = banner && Array.isArray(banner.lights) ? banner.lights : [];
    var layers = [];
    for (var i = 0; i < lights.length && i < 6; i++) {
      var light = lights[i] || {};
      var color = colors[Number(light.color_index) || 0] || '#b39af4';
      var pos = Array.isArray(light.position) ? light.position : [0.5, 0.5];
      var x = Math.max(0, Math.min(1, Number(pos[0]) || 0)) * 100;
      var y = Math.max(0, Math.min(1, Number(pos[1]) || 0)) * 100;
      var strength = Math.max(0.15, Math.min(1, Number(light.strength) || 0.6));
      var rgb = hexRgb(color);
      layers.push('radial-gradient(circle at ' + x.toFixed(1) + '% ' + y.toFixed(1) + '%, rgba(' +
        rgb + ', ' + (strength * 0.8).toFixed(2) + ') 0%, rgba(' + rgb + ', 0) 58%)');
    }
    layers.push('linear-gradient(135deg, ' + bg + ', ' + bg + ')');
    return layers.join(', ');
  }

  /** Фон строки аккаунта: своё медиа, иначе свой градиент баннера. */
  function accountBackground(entry) {
    var details = state.details[entry.profile.id] || {};
    var media = details.mediaBanner && details.mediaBanner.url ? safeUrl(details.mediaBanner.url) : '';
    if (media) {
      return 'linear-gradient(180deg, rgba(17, 17, 19, .5), rgba(17, 17, 19, .74)), url("' +
        media.replace(/"/g, '%22') + '")';
    }
    return bannerBackground(details.banner);
  }

  function paintMusicBack(details) {
    if (!els.music) return;
    els.music.style.backgroundImage =
      'linear-gradient(180deg, rgba(17, 17, 19, .3), rgba(17, 17, 19, .55)), ' +
      bannerBackground(details.banner);
  }

  function stopMusic() {
    if (els.audio) els.audio.pause();
    if (els.music) els.music.classList.remove('is-playing');
    if (els.musicPlay) {
      els.musicPlay.setAttribute('aria-pressed', 'false');
      els.musicPlay.setAttribute('aria-label', 'Включить музыку профиля');
    }
    renderTrackList();
  }

  function paintMusicProgress(seconds, duration) {
    if (els.musicFill) {
      var share = duration > 0 ? Math.min(1, seconds / duration) : 0;
      els.musicFill.style.width = (share * 100).toFixed(2) + '%';
    }
    if (els.musicTime) els.musicTime.textContent = formatTime(seconds);
  }

  function currentTrack() {
    return state.tracks[state.trackIndex] || null;
  }

  function paintMusic(tracks) {
    state.tracks = Array.isArray(tracks) ? tracks : [];
    state.trackIndex = 0;
    var track = currentTrack();
    if (!track || !els.music) {
      if (els.music) els.music.hidden = true;
      return;
    }
    els.music.hidden = false;
    els.musicTitle.textContent = String(track.name || 'Музыка профиля');
    var artist = String(track.artist || '').trim();
    els.musicArtist.textContent = artist;
    els.musicArtist.hidden = !artist;

    var cover = safeUrl(track.cover_url);
    els.musicCover.hidden = false;
    els.musicCover.classList.toggle('has-image', Boolean(cover));
    els.musicCover.style.backgroundImage = cover ? 'url("' + cover.replace(/"/g, '%22') + '")' : '';

    var audioUrl = safeUrl(track.url);
    var playable = Boolean(audioUrl && els.audio);
    els.musicPlay.hidden = !playable;
    if (els.audio) {
      els.audio.onended = stopMusic;
      if (playable) {
        els.audio.src = audioUrl;
      } else {
        els.audio.removeAttribute('src');
      }
    }
    paintMusicProgress(0, Number(track.duration_ms || 0) / 1000);
    renderTrackList();
  }

  function playTrack(index) {
    if (!state.tracks.length) return;
    var track = state.tracks[index];
    if (!track) return;
    var audioUrl = safeUrl(track.url);
    if (!audioUrl || !els.audio) {
      hint('У этого трека нет аудиофайла');
      return;
    }
    var changed = index !== state.trackIndex;
    state.trackIndex = index;
    if (changed) {
      els.musicTitle.textContent = String(track.name || 'Музыка профиля');
      var artist = String(track.artist || '').trim();
      els.musicArtist.textContent = artist;
      els.musicArtist.hidden = !artist;
      var cover = safeUrl(track.cover_url);
      els.musicCover.classList.toggle('has-image', Boolean(cover));
      els.musicCover.style.backgroundImage = cover ? 'url("' + cover.replace(/"/g, '%22') + '")' : '';
      els.audio.src = audioUrl;
      paintMusicProgress(0, Number(track.duration_ms || 0) / 1000);
    }
    els.audio.play().then(function () {
      els.music.classList.add('is-playing');
      els.musicPlay.setAttribute('aria-pressed', 'true');
      els.musicPlay.setAttribute('aria-label', 'Выключить музыку профиля');
      renderTrackList();
    }).catch(function () { stopMusic(); });
  }

  function toggleMusic() {
    if (!els.audio || !els.audio.src) return;
    if (els.audio.paused) {
      playTrack(state.trackIndex);
    } else {
      stopMusic();
    }
  }

  function renderTrackList() {
    if (!els.trackList) return;
    els.trackList.replaceChildren();
    if (els.musicCount) {
      els.musicCount.textContent = state.tracks.length
        ? state.tracks.length + ' ' + (state.tracks.length === 1 ? 'трек' : 'трека')
        : 'Плейлист пуст';
    }
    for (var i = 0; i < state.tracks.length; i++) {
      els.trackList.append(trackRow(state.tracks[i], i));
    }
  }

  function trackRow(track, index) {
    var playing = index === state.trackIndex && els.audio && !els.audio.paused;
    var row = document.createElement('button');
    row.type = 'button';
    row.className = 'track' + (index === state.trackIndex ? ' is-current' : '');

    var cover = document.createElement('span');
    cover.className = 'track-cover';
    var image = safeUrl(track.cover_url);
    if (image) {
      cover.classList.add('has-image');
      cover.style.backgroundImage = 'url("' + image.replace(/"/g, '%22') + '")';
    }

    var copy = document.createElement('span');
    copy.className = 'track-copy';
    var name = document.createElement('span');
    name.className = 'track-name';
    name.textContent = String(track.name || 'Трек');
    var artist = document.createElement('span');
    artist.className = 'track-artist';
    artist.textContent = String(track.artist || '');
    copy.append(name, artist);

    var tail = document.createElement('span');
    if (playing) {
      tail.className = 'track-bars';
      tail.setAttribute('aria-label', 'Играет');
      tail.innerHTML = '<i></i><i></i><i></i>';
    } else {
      tail.className = 'track-state';
      tail.textContent = formatTime(Number(track.duration_ms || 0) / 1000);
    }

    row.append(cover, copy, tail);
    row.addEventListener('click', function () {
      if (playing) stopMusic();
      else playTrack(index);
    });
    return row;
  }

  // ── Рендер профиля ───────────────────────────────

  function renderActive(entry) {
    if (!entry) {
      els.active.hidden = true;
      stopMusic();
      return;
    }
    var profile = entry.profile;
    var details = state.details[profile.id] || {};
    els.active.hidden = false;

    paintAvatar(els.avatar, profile);
    paintBanner(details);
    paintMusicBack(details);
    els.name.textContent = profile.display_name || ('@' + (profile.username || 'ghost'));
    els.verified.hidden = !details.verified;
    els.handle.textContent = profile.username ? '@' + profile.username : '';

    els.following.textContent = formatCount(details.following_count);
    els.followers.textContent = formatCount(details.followers_count);
    els.likes.textContent = formatCount(details.likes_received);

    var about = String(details.about || '').trim();
    els.about.textContent = about;
    els.about.hidden = !about;

    var joined = joinedLabel(details.created_at);
    els.joinedText.textContent = joined;
    els.joined.hidden = !joined;

    paintMusic(details.profile_music);

    els.activeId.textContent = 'GhostID ' + profile.id;
    if (els.activeBalance) {
      var balance = normalBalance(details.balance);
      els.activeBalance.hidden = balance == null;
      els.activeBalance.textContent = balance == null ? '' : balance + ' GOST';
    }
    els.editActive.disabled = Boolean(details.expired);
    els.logoutActive.disabled = false;
  }

  function accountRow(entry) {
    var row = document.createElement('div');
    row.className = 'account';
    row.setAttribute('role', 'listitem');
    row.style.backgroundImage = accountBackground(entry);
    row.style.backgroundSize = 'cover';
    row.style.backgroundPosition = 'center';

    var switchBtn = document.createElement('button');
    switchBtn.type = 'button';
    switchBtn.className = 'account-switch';
    switchBtn.title = 'Переключиться на @' + entry.profile.username;

    var avatar = document.createElement('span');
    avatar.className = 'account-avatar';
    paintAvatar(avatar, entry.profile);

    var copy = document.createElement('span');
    copy.className = 'account-copy';
    var name = document.createElement('strong');
    name.className = 'account-name';
    name.textContent = entry.profile.display_name || ('@' + entry.profile.username);
    var handle = document.createElement('span');
    handle.className = 'account-handle';
    handle.textContent = '@' + entry.profile.username + ' · GhostID ' + entry.profile.id;
    copy.append(name, handle);
    switchBtn.append(avatar, copy);
    switchBtn.addEventListener('click', function () { activate(entry); });

    var actions = document.createElement('div');
    actions.className = 'account-actions';

    var edit = document.createElement('button');
    edit.type = 'button';
    edit.className = 'icon-btn';
    edit.title = 'Изменить профиль';
    edit.setAttribute('aria-label', 'Изменить профиль @' + entry.profile.username);
    edit.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 20h4L19 9l-4-4L4 16v4Zm11.5-14.5 4 4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    edit.addEventListener('click', function () { openEditor(entry); });

    var drop = document.createElement('button');
    drop.type = 'button';
    drop.className = 'icon-btn danger';
    drop.title = 'Убрать с устройства';
    drop.setAttribute('aria-label', 'Убрать @' + entry.profile.username + ' с устройства');
    drop.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 7l10 10M17 7 7 17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>';
    drop.addEventListener('click', function () { forget(entry); });

    actions.append(edit, drop);
    row.append(switchBtn, actions);
    return row;
  }

  function render() {
    var active = activeEntry();
    var list = store.list();
    var others = active
      ? list.filter(function (item) { return item.profile.id !== active.profile.id; })
      : list;

    renderActive(active);

    var hasAny = Boolean(active) || list.length > 0;
    els.empty.hidden = hasAny;
    els.listWrap.hidden = !hasAny;
    if (!hasAny) return;

    els.listTitle.textContent = others.length ? 'Другие аккаунты' : 'Аккаунты на устройстве';
    els.count.textContent = list.length ? list.length + ' из ' + store.MAX : '';
    els.list.replaceChildren();
    for (var i = 0; i < others.length; i++) {
      els.list.append(accountRow(others[i]));
    }
    els.list.hidden = !others.length;

    for (var j = 0; j < list.length; j++) {
      var item = list[j];
      if (!state.details[item.profile.id] && !state.loading[item.profile.id]) {
        loadDetails(item);
      }
    }
  }

  // ── Данные активного аккаунта ────────────────────

  async function loadDetails(entry) {
    if (!entry) return;
    var id = entry.profile.id;
    if (state.loading[id]) return;
    state.loading[id] = true;
    var headers = apiHeaders(entry.token);
    var me = null;
    try {
      var response = await fetch(ME, { credentials: 'include', cache: 'no-store', headers: headers });
      if (response.ok) {
        me = await response.json();
        if (me && (me.id || me.user_id)) {
          me.avatar_url = me.avatar_url || '';
        }
      } else if (response.status === 401 || response.status === 403) {
        state.loading[id] = false;
        state.details[id] = Object.assign({}, state.details[id], { expired: true });
        if (activeEntry() && activeEntry().profile.id === id) {
          renderActive(entry);
          hint('Сессия @' + entry.profile.username + ' истекла. Убери аккаунт или войди снова.');
        }
        return;
      }
    } catch (_) {
      state.loading[id] = false;
      return;
    }

    var details = state.details[id] || {};
    if (me) {
      details.about = String(me.about || '');
      details.username = String(me.username || '');
      details.display_name = String(me.display_name || '');
      details.created_at = String(me.created_at || '');
      details.verified = Boolean(me.is_verified);
      details.banner = me.banner && typeof me.banner === 'object' ? me.banner : null;
      details.mediaBanner = me.media_banner && typeof me.media_banner === 'object' ? me.media_banner : null;
      details.profile_music = Array.isArray(me.profile_music) ? me.profile_music : [];
      details.followers_count = me.followers_count;
      details.following_count = me.following_count;
      details.likes_received = me.likes_received;
      delete details.expired;
      entry.profile.username = details.username || entry.profile.username;
      entry.profile.display_name = details.display_name || entry.profile.display_name;
      if (me.avatar_url) entry.profile.avatar_url = me.avatar_url;
    }

    try {
      var wallet = await fetch(WALLET, { credentials: 'include', cache: 'no-store', headers: headers });
      if (wallet.ok) {
        var data = await wallet.json();
        var balance = normalBalance(data && data.balance);
        if (balance != null) details.balance = balance;
      }
    } catch (_) {}

    state.details[id] = details;
    state.loading[id] = false;
    var current = activeEntry();
    if (current && current.profile.id === id) {
      renderActive(entry);
    }
    render();
  }

  // ── Действия ─────────────────────────────────────

  function activate(entry) {
    var picked = store.activate(entry.profile.id);
    if (!picked) {
      hint('Не удалось переключить аккаунт');
      return;
    }
    hint('Переключились на @' + picked.profile.username, true);
    render();
    loadDetails(picked);
  }

  function forget(entry) {
    var wasActive = store.currentToken() === entry.token;
    store.remove(entry.profile.id);
    delete state.details[entry.profile.id];
    if (wasActive) {
      clearSession();
      var rest = store.list();
      if (rest.length) {
        store.activate(rest[0].profile.id);
        hint('Вышел из @' + entry.profile.username + '. Активен @' + rest[0].profile.username, true);
      } else {
        hint('Аккаунт убран с устройства');
      }
    } else {
      hint('Аккаунт @' + entry.profile.username + ' убран с устройства', true);
    }
    render();
    loadDetails(activeEntry());
  }

  function goAddAccount() {
    location.href = AUTH_URL;
  }

  // ── Список музыки ────────────────────────────────

  function openMusic() {
    if (!state.tracks.length || !els.musicSheet) return;
    renderTrackList();
    els.musicSheet.hidden = false;
  }

  function closeMusic() {
    if (els.musicSheet) els.musicSheet.hidden = true;
  }

  // ── Редактор профиля ─────────────────────────────

  async function openEditor(entry) {
    state.editingId = entry.profile.id;
    state.editorAvatar = entry.profile.avatar_url || '';
    els.editorAccount.textContent = '@' + entry.profile.username + ' · GhostID ' + entry.profile.id;
    els.editorName.value = entry.profile.display_name || '';
    els.editorAbout.value = '';
    editorStatus('');
    paintAvatar(els.editorAvatar, entry.profile);
    els.editor.hidden = false;
    els.editorSave.disabled = false;
    try { els.editorName.focus({ preventScroll: true }); } catch (_) { els.editorName.focus(); }

    var details = state.details[entry.profile.id] || {};
    if (details.about == null) {
      try {
        var response = await fetch(ME, { credentials: 'include', cache: 'no-store', headers: apiHeaders(entry.token) });
        if (response.ok) {
          var me = await response.json();
          details.about = String(me.about || '');
          state.details[entry.profile.id] = details;
        }
      } catch (_) {}
    }
    if (state.editingId === entry.profile.id) {
      els.editorAbout.value = details.about || '';
    }
  }

  function closeEditor() {
    els.editor.hidden = true;
    state.editingId = '';
    state.editorAvatar = '';
    els.avatarInput.value = '';
  }

  function refreshEntry(entry, patch) {
    entry.profile = Object.assign({}, entry.profile, patch);
    store.add(entry.token, {
      id: entry.profile.id,
      username: entry.profile.username,
      display_name: entry.profile.display_name,
      avatar_url: entry.profile.avatar_url,
      is_guest: false
    }).catch(function () {});
    if (store.currentToken() === entry.token) {
      var cached = cachedMe();
      try { localStorage.setItem('gs_me', JSON.stringify(Object.assign({}, cached, patch, { token: entry.token }))); } catch (_) {}
    }
  }

  async function saveProfile() {
    if (state.saving) return;
    var entry = entryById(state.editingId);
    if (!entry) { closeEditor(); return; }
    var name = els.editorName.value.trim();
    var about = els.editorAbout.value.trim();
    if (!name) {
      editorStatus('Имя не может быть пустым');
      return;
    }
    state.saving = true;
    els.editorSave.disabled = true;
    editorStatus('');
    try {
      var response = await fetch(PROFILE, {
        method: 'PATCH',
        credentials: 'include',
        headers: Object.assign({ 'Content-Type': 'application/json' }, apiHeaders(entry.token)),
        body: JSON.stringify({ display_name: name, about: about })
      });
      if (!response.ok) {
        editorStatus(await readError(response, 'Не удалось сохранить профиль'));
        return;
      }
      var data = await response.json();
      var patch = {
        display_name: String(data.display_name || name),
        username: String(data.username || entry.profile.username),
        avatar_url: state.editorAvatar || entry.profile.avatar_url || ''
      };
      var details = state.details[entry.profile.id] || {};
      details.about = String(data.about == null ? about : data.about);
      state.details[entry.profile.id] = details;
      refreshEntry(entry, patch);
      closeEditor();
      render();
      hint('Профиль обновлён', true);
    } catch (_) {
      editorStatus('Нет связи с сервером. Попробуй ещё раз.');
    } finally {
      state.saving = false;
      els.editorSave.disabled = false;
    }
  }

  async function uploadAvatar(file) {
    var entry = entryById(state.editingId);
    if (!entry || !file) return;
    if (ALLOWED_TYPES.indexOf(file.type) === -1) {
      editorStatus('Только JPEG, PNG или WebP');
      return;
    }
    if (file.size > MAX_UPLOAD) {
      editorStatus('Файл больше 5 МБ');
      return;
    }
    if (state.busyAvatar) return;
    state.busyAvatar = true;
    editorStatus('Загружаю фото…', true);
    var form = new FormData();
    form.append('file', file);
    try {
      var response = await fetch(AVATAR, {
        method: 'POST',
        credentials: 'include',
        headers: apiHeaders(entry.token),
        body: form
      });
      if (!response.ok) {
        editorStatus(await readError(response, 'Не удалось загрузить фото'));
        return;
      }
      var data = await response.json();
      state.editorAvatar = String(data.avatar_url || '');
      refreshEntry(entry, { avatar_url: state.editorAvatar });
      paintAvatar(els.editorAvatar, entry.profile);
      render();
      editorStatus('Фото обновлено', true);
    } catch (_) {
      editorStatus('Нет связи с сервером');
    } finally {
      state.busyAvatar = false;
      els.avatarInput.value = '';
    }
  }

  async function removeAvatar() {
    var entry = entryById(state.editingId);
    if (!entry || state.busyAvatar) return;
    state.busyAvatar = true;
    editorStatus('');
    try {
      var response = await fetch(AVATAR, {
        method: 'DELETE',
        credentials: 'include',
        headers: apiHeaders(entry.token)
      });
      if (!response.ok) {
        editorStatus(await readError(response, 'Не удалось снять фото'));
        return;
      }
      state.editorAvatar = '';
      refreshEntry(entry, { avatar_url: '' });
      paintAvatar(els.editorAvatar, entry.profile);
      render();
      editorStatus('Фото снято', true);
    } catch (_) {
      editorStatus('Нет связи с сервером');
    } finally {
      state.busyAvatar = false;
    }
  }

  // ── Связывание событий ───────────────────────────

  if (els.avatar) {
    els.avatar.classList.add('is-clickable');
    els.avatar.addEventListener('click', function () {
      var entry = activeEntry();
      if (entry) openEditor(entry);
    });
  }
  if (els.editActive) {
    els.editActive.addEventListener('click', function () {
      var entry = activeEntry();
      if (entry) openEditor(entry);
    });
  }
  if (els.logoutActive) {
    els.logoutActive.addEventListener('click', function () {
      var entry = activeEntry();
      if (entry) forget(entry);
    });
  }
  if (els.musicPlay) els.musicPlay.addEventListener('click', toggleMusic);
  if (els.musicOpen) els.musicOpen.addEventListener('click', openMusic);
  if (els.musicSheetClose) els.musicSheetClose.addEventListener('click', closeMusic);
  if (els.musicSheet) {
    els.musicSheet.addEventListener('click', function (event) {
      if (event.target === els.musicSheet) closeMusic();
    });
  }
  if (els.audio) {
    els.audio.addEventListener('timeupdate', function () {
      paintMusicProgress(els.audio.currentTime, els.audio.duration || 0);
    });
    els.audio.addEventListener('pause', function () {
      if (els.music) els.music.classList.remove('is-playing');
    });
    els.audio.addEventListener('play', function () {
      if (els.music) els.music.classList.add('is-playing');
    });
  }
  if (els.add) els.add.addEventListener('click', goAddAccount);
  if (els.editorClose) els.editorClose.addEventListener('click', closeEditor);
  if (els.editorCancel) els.editorCancel.addEventListener('click', closeEditor);
  if (els.editorSave) els.editorSave.addEventListener('click', saveProfile);
  if (els.avatarInput) {
    els.avatarInput.addEventListener('change', function () {
      var file = els.avatarInput.files && els.avatarInput.files[0];
      if (file) uploadAvatar(file);
    });
  }
  if (els.avatarRemove) els.avatarRemove.addEventListener('click', removeAvatar);
  if (els.editor) {
    els.editor.addEventListener('click', function (event) {
      if (event.target === els.editor) closeEditor();
    });
  }
  document.addEventListener('keydown', function (event) {
    if (event.key !== 'Escape') return;
    if (els.musicSheet && !els.musicSheet.hidden) closeMusic();
    if (!els.editor.hidden) closeEditor();
  });
  document.addEventListener('ghostid-accounts-changed', function () {
    render();
    loadDetails(activeEntry());
  });

  // ── Запуск ───────────────────────────────────────

  render();
  loadDetails(activeEntry());
  store.sync().then(function () {
    render();
    loadDetails(activeEntry());
  }).catch(function () {
    render();
  });
})();
