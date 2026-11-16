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
    profileHost: document.getElementById('idProfile'),
    activeBalance: document.querySelector('[data-active-balance]'),
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

/* Фрагмент GhostSocial: скопирован из /var/www/ghostsocial/assets/app.js без изменений.
   Обвязка GhostID (me, socialAuthHeaders, v2Loading) живёт в id.js. */

function gsProfileImageSource(value, depth) {
  if (typeof value === 'string') return value;
  if (!value || typeof value !== 'object' || (depth || 0) > 3) return '';
  const candidate = value.url || value.src || value.image_url || value.avatar_url ||
    value.banner_url || value.background_image || value.image;
  return typeof candidate === 'string' ? candidate : gsProfileImageSource(candidate, (depth || 0) + 1);
}

function gsProfileSafeUrl(value) {
  try {
    const url = new URL(String(value || ''), location.origin);
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : '';
  } catch (_) { return ''; }
}

  // ── Обвязка GhostID вокруг скопированного кода ────

  var me = null;

  /** Фон строки аккаунта: своё медиа, иначе свой градиент баннера. */
  function bannerDesign(rawBanner) {
    var settings = (rawBanner && typeof rawBanner === 'object') ? (rawBanner.config || rawBanner) : {};
    var colors = Array.isArray(settings.colors) ? settings.colors.filter(Boolean) : [];
    var color = settings.background_color || '#171026';
    var type = String(settings.type || 'solid').toLowerCase();
    if (type === 'solid' && colors.length) return { color: colors[0], image: 'none' };
    if (type === 'linear' && colors.length) {
      var angle = Number(settings.angle) || 135;
      return { color: color, image: 'linear-gradient(' + angle + 'deg, ' + colors.join(', ') + ')' };
    }
    var lights = Array.isArray(settings.lights) ? settings.lights : [];
    var layers = [];
    for (var i = 0; i < lights.length && i < colors.length; i++) {
      var light = lights[i] || {};
      var pos = Array.isArray(light.position) ? light.position : [0.5, 0.5];
      var strength = light.strength == null ? 0.65 : Number(light.strength);
      var rgb = String(colors[Number(light.color_index) || 0] || '')
        .replace('#', '').match(/../g) || ['00', '00', '00'];
      layers.push('radial-gradient(ellipse ' + (59 + Math.round(strength * 10)) + '% ' +
        (107 + Math.round(strength * 10)) + '% at ' + Math.round(pos[0] * 100) + '% ' +
        Math.round(pos[1] * 100) + '%, rgba(' + rgb.map(function (p) { return parseInt(p, 16); }).join(', ') +
        ', ' + (strength * 0.45).toFixed(3) + ') 0%, transparent 100%)');
    }
    return { color: color, image: layers.length ? layers.join(',') : 'none' };
  }

  /** Аватарка строки списка — фоном. */
  function paintAvatar(node, profile) {
    if (!node) return;
    var url = gsProfileSafeUrl(gsProfileImageSource((profile || {}).avatar_url));
    node.replaceChildren();
    node.textContent = url ? '' : initial(profile || {});
    node.style.backgroundImage = url ? 'url("' + url.replace(/"/g, '%22') + '")' : '';
  }

  var profileView = null;
  var profileViewUser = '';

  /** Профиль рисует модуль соцсети; пересоздаём только при смене аккаунта. */
  function syncProfileCard(username) {
    var host = document.getElementById('idProfile');
    var name = String(username || '');
    if (!host || !name || !window.GeProfile) return;
    if (profileView && profileViewUser === name) return;
    if (profileView) {
      try { profileView.destroy(); } catch (_) {}
      profileView = null;
    }
    host.replaceChildren();
    profileView = window.GeProfile.connect(host, { username: name });
    profileViewUser = name;
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

  /** Фон строки аккаунта: своё медиа, иначе свой градиент баннера. */
  function accountBackground(entry) {
    const details = state.details[entry.profile.id] || {};
    const media = details.mediaBanner && details.mediaBanner.url
      ? gsProfileSafeUrl(details.mediaBanner.url) : '';
    if (media) {
      return 'linear-gradient(180deg, rgba(17, 17, 19, .5), rgba(17, 17, 19, .74)), url("' +
        media.replace(/"/g, '%22') + '")';
    }
    return bannerDesign(details.banner).image;
  }


  // ── Рендер профиля ───────────────────────────────

  function renderActive(entry) {
    if (!entry) {
      els.active.hidden = true;
      if (profileView) {
        try { profileView.destroy(); } catch (_) {}
        profileView = null;
        profileViewUser = '';
      }
      return;
    }
    var profile = entry.profile;
    var details = state.details[profile.id] || {};
    els.active.hidden = false;

    syncProfileCard(profile.username || details.username);
    if (els.activeBalance) {
      var balance = normalBalance(details.balance);
      els.activeBalance.hidden = balance == null;
      els.activeBalance.textContent = balance == null ? '' : balance + ' GOST';
    }
    if (els.logoutActive) els.logoutActive.disabled = Boolean(details.expired);
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
      details.raw = me;
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

  if (els.logoutActive) {
    els.logoutActive.addEventListener('click', function () {
      var entry = activeEntry();
      if (entry) forget(entry);
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
    if (els.editor && !els.editor.hidden) closeEditor();
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
