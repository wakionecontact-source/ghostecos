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
    banner: document.getElementById('profBanner'),
    bannerImage: document.getElementById('profBannerImage'),
    avatar: document.getElementById('profAv'),
    name: document.getElementById('profName'),
    badges: document.getElementById('profBadges'),
    verified: null,
    handle: document.getElementById('profUser'),
    following: document.getElementById('sFollowing'),
    followers: document.getElementById('sFollowers'),
    likes: document.getElementById('sReceived'),
    about: document.getElementById('profBio'),
    joined: document.getElementById('profCreated'),
    joinedText: document.getElementById('profCreatedText'),
    music: document.getElementById('profMusic'),
    musicCover: document.getElementById('profMusicCover'),
    musicTitle: document.getElementById('profMusicTitle'),
    musicArtist: document.getElementById('profMusicArtist'),
    musicTime: document.querySelector('[data-music-time]'),
    musicFill: document.querySelector('[data-music-fill]'),
    musicOpen: document.getElementById('profMusicListBtn'),
    musicPlay: document.getElementById('profMusicPlay'),
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

function gsProfilePosition(value, fallback) {
  fallback = fallback || '50% 50%';
  if (Array.isArray(value) && value.length >= 2) {
    const raw = value.slice(0, 2).map(Number);
    const scale = raw.some(number => Math.abs(number) > 1) ? 100 : 1;
    return raw.map(number => Number.isFinite(number)
      ? Math.round(Math.min(1, Math.max(0, number / scale)) * 100) + '%'
      : '50%').join(' ');
  }
  if (value && typeof value === 'object' && value.x != null && value.y != null)
    return gsProfilePosition([value.x, value.y], fallback);
  if (typeof value === 'string' && /^[a-z0-9.% -]{1,40}$/i.test(value.trim())) return value.trim();
  return fallback;
}

function gsProfileBannerHex(value, fallback) {
  const hex = String(value || '').trim().replace(/^#/, '');
  return /^[0-9a-f]{6}$/i.test(hex) ? '#' + hex.toUpperCase() : fallback;
}

function gsProfileBannerRgb(hex) {
  return (hex.slice(1).match(/../g) || ['00', '00', '00']).map(part => parseInt(part, 16)).join(',');
}

function gsProfileRenderBanner(prefix, data) {
  const cover = document.getElementById(prefix + 'Banner');
  const image = document.getElementById(prefix + 'BannerImage');
  if (!cover || !image) return;
  let raw = data.banner || data.banner_config || data.banner_settings;
  let config = raw;
  let rawImage = '';
  if (typeof raw === 'string') {
    try { config = JSON.parse(raw); }
    catch (_) { config = null; rawImage = raw; }
  }
  const nested = config && typeof config === 'object' ? config : {};
  const settings = nested.config && typeof nested.config === 'object' ? nested.config : nested;
  const colors = Array.isArray(settings.colors)
    ? settings.colors.map(color => gsProfileBannerHex(color, '')).filter(Boolean) : [];
  let background = gsProfileBannerHex(settings.background_color, '#171026');
  let base = '';
  const layers = [];
  const clamp = (value, min, max) => Math.min(max, Math.max(min, Number.isFinite(Number(value)) ? Number(value) : min));
  const type = String(settings.type || 'solid').toLowerCase();
  if (type === 'solid' && colors.length) background = colors[0];
  else if (type === 'linear' && colors.length) {
    const angle = clamp(settings.angle == null ? 135 : settings.angle, -360, 360);
    const stops = Array.isArray(settings.stops) ? settings.stops : [];
    const points = colors.map((color, index) => {
      const stop = stops[index] != null ? clamp(stops[index], 0, 1) : (colors.length === 1 ? 0 : index / (colors.length - 1));
      return color + ' ' + Math.round(stop * 100) + '%';
    });
    base = 'linear-gradient(' + angle + 'deg, ' + points.join(', ') + ')';
  } else if (type === 'lights') background = gsProfileBannerHex(settings.background_color, '#020617');
  let lights = Array.isArray(settings.lights) ? settings.lights.slice(0, 10) : [];
  if (type === 'lights' && colors.length) {
    const hasIndexedLights = lights.some(light => light && light.color_index != null);
    const edgePoint = (index, count) => {
      const t = ((index + 0.5) / Math.max(1, count)) * 4;
      if (t < 1) return [t, 0];
      if (t < 2) return [1, t - 1];
      if (t < 3) return [3 - t, 1];
      return [0, 4 - t];
    };
    lights = colors.map((_, index) => {
      const configured = lights.find(light => light && Number(light.color_index) === index) ||
        (!hasIndexedLights ? lights[index] : null);
      if (configured && Array.isArray(configured.position) && configured.position.length >= 2) return configured;
      return { color_index: index, position: edgePoint(index, colors.length), strength: 0.48 };
    });
  }
  lights.slice(0, 10).forEach((light, fallbackIndex) => {
    if (!colors.length || !light || !Array.isArray(light.position) || light.position.length < 2) return;
    const index = Math.trunc(clamp(light.color_index == null ? (type === 'lights' ? fallbackIndex : 0) : light.color_index, 0, colors.length - 1));
    const rgb = gsProfileBannerRgb(colors[index]);
    const x = Math.round(clamp(light.position[0], 0, 1) * 100);
    const y = Math.round(clamp(light.position[1], 0, 1) * 100);
    const strength = clamp(light.strength == null ? 0.65 : light.strength, 0, 1);
    if (strength <= 0) return;
    const radiusX = 59 + Math.round(strength * 10);
    const radiusY = 107 + Math.round(strength * 10);
    layers.push('radial-gradient(ellipse ' + radiusX + '% ' + radiusY + '% at ' + x + '% ' + y +
      '%, rgba(' + rgb + ', ' + (strength * 0.45).toFixed(3) + ') 0%, transparent 100%)');
  });
  if (type !== 'solid' && colors.length && !layers.length && Array.isArray(settings.light)) {
    const x = Math.round(clamp(settings.light[0], 0, 1) * 100);
    const y = Math.round(clamp(settings.light[1], 0, 1) * 100);
    layers.unshift('radial-gradient(ellipse 65% 130% at ' + x + '% ' + y +
      '%, rgba(' + gsProfileBannerRgb(colors[0]) + ', .62), transparent 72%)');
  }
  if (base) layers.push(base);
  const designedImage = layers.length ? layers.join(',') : ((colors.length || gsProfileBannerHex(settings.background_color, '')) ? 'none' : 'linear-gradient(120deg,#301754,#171026 72%)');
  cover.style.backgroundColor = background;
  cover.style.backgroundImage = designedImage;
  cover._gsBannerDesign = { color: background, image: designedImage }; // musictint-20261112
  const source = data.banner_url || data.profile_banner_url || data.banner_image_url || data.cover_url ||
    gsProfileImageSource(nested) || rawImage;
  const url = gsProfileSafeUrl(source);
  image.hidden = !url;
  if (!url) { image.removeAttribute('src'); return; }
  image.style.objectPosition = gsProfilePosition(
    data.banner_position || data.banner_focus || nested.position || nested.focal_point
  );
  image.onerror = () => { image.hidden = true; image.removeAttribute('src'); };
  if (image.getAttribute('src') !== url) image.src = url;
}

function gsProfileSetAvatar(element, data, displayName) {
  if (!element) return '';
  const source = data.avatar_url || data.profile_avatar_url || data.profile_picture_url || data.avatar;
  const url = gsProfileSafeUrl(gsProfileImageSource(source));
  const initial = Array.from(String(displayName || data.username || data.gc_username || '?'))[0] || '?';
  element.replaceChildren();
  element.textContent = initial.toUpperCase();
  element.style.background = url ? 'transparent' : '';
  element.style.cursor = url ? 'pointer' : '';
  if (!url) return '';
  const image = document.createElement('img');
  image.src = url;
  image.alt = '';
  image.loading = 'eager';
  image.decoding = 'async';
  image.referrerPolicy = 'no-referrer';
  image.style.objectPosition = gsProfilePosition(data.avatar_position || data.avatar_focus);
  image.style.width = '100%';
  image.style.height = '100%';
  image.style.objectFit = 'cover';
  image.addEventListener('error', () => {
    element.replaceChildren();
    element.textContent = initial.toUpperCase();
    element.style.background = '';
    element.style.cursor = '';
  }, { once: true });
  element.replaceChildren(image);
  return url;
}

function gsProfileBannerNotchController(node) {
  if (!node || node.dataset.gsNotchController === '1') return;
  node.dataset.gsNotchController = '1';
  const card = node.parentElement;
  let gradient = card && card.querySelector(':scope > .gs-banner-avatar-gradient');
  if (card && !gradient) {
    gradient = document.createElement('div');
    gradient.className = 'gs-banner-avatar-gradient';
    gradient.setAttribute('aria-hidden', 'true');
    card.appendChild(gradient);
  }
  const positionGradient = () => {
    if (!gradient || !card) return;
    gradient.style.top = Math.max(0, node.offsetTop + node.offsetHeight - 1) + 'px';
    gradient.style.left = node.offsetLeft + 'px';
    gradient.style.width = node.offsetWidth + 'px';
  };
  positionGradient();
  if (typeof ResizeObserver !== 'undefined' && !node._gsGradientResizeObserver) {
    node._gsGradientResizeObserver = new ResizeObserver(positionGradient);
    node._gsGradientResizeObserver.observe(node);
  }
  let open = false;
  let timer = null;
  let generation = 0;
  let lastTapAt = 0;
  const setOpen = (next, duration = 750) => {
    generation++;
    if (timer) { clearTimeout(timer); timer = null; }
    open = !!next;
    node.style.setProperty('--gs-banner-notch-radius', open ? '0px' : '72px');
    node.style.setProperty('--gs-banner-notch-duration', duration + 'ms');
    node.classList.remove('gs-banner-notch-wave');
    node.classList.toggle('gs-banner-notch-open', open);
    if (gradient) gradient.classList.toggle('is-visible', open);
    positionGradient();
    node.setAttribute('aria-expanded', open ? 'true' : 'false');
    return generation;
  };
  node.addEventListener('click', (event) => {
    if (!node.classList.contains('gs-banner-media-loaded')) return;
    event.preventDefault();
    event.stopPropagation();
    const now = Date.now();
    if (now - lastTapAt < 90) return;
    lastTapAt = now;
    setOpen(!open, 550);
  });
  node._gsBannerNotchPlay = () => {
    const current = setOpen(true, 850);
    timer = setTimeout(() => {
      if (current !== generation) return;
      const next = setOpen(false, 550);
      timer = setTimeout(() => { if (next === generation) timer = null; }, 700);
    }, 4050);
  };
}

function gsProfileRenderMediaBanner(prefix, data) {
  const node = document.getElementById(prefix + 'Banner');
  const fallbackImage = document.getElementById(prefix + 'BannerImage');
  if (!node) return;
  const banner = data && data.media_banner;
  const rawUrl = banner && banner.url;
  const url = gsProfileSafeUrl(rawUrl);
  // This is one banner element with two modes: gradient fallback and media.
  // Remove only previously inserted media/status nodes, never the banner itself.
  node.querySelectorAll('.gs-banner-media, .gs-banner-media-shade, .gs-media-banner-status').forEach(el => el.remove());
  node.classList.remove('gs-banner-mode-media', 'gs-banner-media-loaded', 'gs-banner-media-error');
  node.style.setProperty('--gs-banner-notch-radius', '72px');
  gsProfileBannerNotchController(node);
  node.removeAttribute('aria-hidden');
  if (fallbackImage) fallbackImage.hidden = false;
  if (!rawUrl) return;
  if (!url) {
    node.classList.add('gs-banner-media-error');
    const status = document.createElement('div');
    status.className = 'gs-media-banner-status';
    status.textContent = 'Не удалось загрузить баннер';
    node.appendChild(status);
    return;
  }
  const type = banner.type === 'video' ? 'video' : 'image';
  const x = Math.max(0, Math.min(100, Number.isFinite(Number(banner.position_x)) ? Number(banner.position_x) : 50));
  const y = Math.max(0, Math.min(100, Number.isFinite(Number(banner.position_y)) ? Number(banner.position_y) : 50));
  const zoom = Math.max(1, Math.min(3, Number(banner.zoom) || 1));
  const shadeStrength = Math.max(0, Math.min(1, Number(banner.overlay) || 0));
  const blurPx = Math.max(0, Math.min(16, Number(banner.blur) || 0));
  const media = document.createElement(type === 'video' ? 'video' : 'img');
  media.className = 'gs-banner-media';
  media.alt = '';
  // Cover + zoom with an explicit pan: object-position cannot move the media
  // once it is scaled, so the media is sized and offset directly.
  const applyFrame = () => {
    const bw = node.clientWidth;
    const bh = node.clientHeight;
    const iw = media.naturalWidth || media.videoWidth || 0;
    const ih = media.naturalHeight || media.videoHeight || 0;
    if (!bw || !bh || !iw || !ih) return;
    const scale = Math.max(bw / iw, bh / ih) * zoom;
    const w = iw * scale;
    const h = ih * scale;
    const ox = Math.max(0, w - bw);
    const oy = Math.max(0, h - bh);
    media.style.inset = 'auto';
    media.style.maxWidth = 'none';
    media.style.maxHeight = 'none';
    media.style.objectFit = 'fill';
    media.style.transform = 'none';
    media.style.width = w + 'px';
    media.style.height = h + 'px';
    media.style.left = (-(x / 100) * ox) + 'px';
    media.style.top = (-(y / 100) * oy) + 'px';
  };
  if (!node._gsBannerFrameObserver && typeof ResizeObserver === 'function') {
    node._gsBannerFrameObserver = new ResizeObserver(() => applyFrame());
    node._gsBannerFrameObserver.observe(node);
  }
  if (blurPx > 0) media.style.filter = 'blur(' + blurPx + 'px)';
  if (type === 'video') { media.autoplay = true; media.loop = true; media.muted = true; media.playsInline = true; media.preload = 'auto'; }
  const status = document.createElement('div');
  status.className = 'gs-media-banner-status';
  status.textContent = '';
  status.hidden = true;
  node.append(media);
  if (shadeStrength > 0) {
    const shade = document.createElement('div');
    shade.className = 'gs-banner-media-shade';
    shade.style.opacity = String(shadeStrength);
    node.append(shade);
  }
  const loaded = () => {
    applyFrame();
    node.classList.add('gs-banner-mode-media', 'gs-banner-media-loaded');
    node.classList.remove('gs-banner-media-error');
    if (fallbackImage) fallbackImage.hidden = true;
    node.style.backgroundImage = 'none';
    status.remove();
    node.style.setProperty('--gs-banner-notch-radius', '72px');
    requestAnimationFrame(() => { if (typeof node._gsBannerNotchPlay === 'function') node._gsBannerNotchPlay(); });
    console.info('[GhostSocial] Unified profile banner media loaded', url);
  };
  const failed = () => {
    media.remove();
    node.classList.remove('gs-banner-mode-media', 'gs-banner-media-loaded');
    node.classList.add('gs-banner-media-error');
    if (fallbackImage) fallbackImage.hidden = true;
    node.classList.remove('gs-banner-mode-media');
    status.remove();
    console.error('[GhostSocial] Unified profile banner media failed', url, media.error || 'load error');
  };
  media.addEventListener(type === 'video' ? 'loadeddata' : 'load', loaded, { once: true });
  media.addEventListener('error', failed, { once: true });
  media.src = url;
  applyFrame();
  if (type === 'video') media.load();
  if (type === 'image' && media.complete && media.naturalWidth > 0) loaded();
}

function gsProfileRenderBadges(prefix, data) {
  const container = document.getElementById(prefix + 'Badges');
  if (!container) return;
  container.replaceChildren();
  const add = (label, kind) => {
    const value = String(label == null ? '' : label).trim();
    if (!value) return;
    const badge = document.createElement('span');
    badge.className = 'gs-profile-badge' + (kind ? ' ' + kind : '');
    badge.textContent = value;
    container.appendChild(badge);
  };
  const customPrefix = String(data.prefix || data.username_prefix || '').trim();
  if (customPrefix) add(customPrefix, 'prefix');
  if (data.is_admin) add('Администратор', 'role');
  else if (data.is_moderator) add('Модератор', 'role');
  const shields = Array.isArray(data.shields) ? data.shields : (Array.isArray(data.badges) ? data.badges : []);
  shields.slice(0, 4).forEach(shield => {
    const label = typeof shield === 'string' ? shield : (shield && (shield.name || shield.label || shield.title));
    if (label) add(label, 'shield');
  });
  container.hidden = !container.childElementCount;
}

function onProfAvClick(ev){
  // Берём свежее avatar_url из DOM — me.avatar_url мог устареть.
  const el = document.getElementById('profAv');
  const img = el && el.querySelector('img');
  const url = (img && img.src) || (me && me.avatar_url);
  if (url){
    openProfAvLightbox(url, (me && (me.display_name || me.username)) || '', true);
  } else {
    document.getElementById('profAvFile').click();
  }
}

async function onProfAvFileChosen(input){
  const f = input.files && input.files[0];
  if (!f) return;
  if (f.size > 5 * 1024 * 1024) { alert('Файл больше 5 МБ'); input.value=''; return; }
  const el = document.getElementById('profAv');
  const prev = el ? el.innerHTML : '';
  if (el) el.innerHTML = v2Loading('avatar', 1, '<i class="fa-solid fa-spinner fa-spin" style="color:#fff;"></i>');
  try {
    const fd = new FormData();
    fd.append('file', f);
    const r = await fetch('/api/soc/me/avatar', {
      method: 'POST',
      headers: socialAuthHeaders({ 'X-Ghost-Web': '1' }),
      credentials: 'include',
      body: fd,
    });
    if (!r.ok) {
      const t = await r.text(); let m = t; try { m = JSON.parse(t).detail || t; } catch(_){}
      throw new Error(m);
    }
    const d = await r.json();
    me.avatar_url = d.avatar_url;
    try { localStorage.setItem('gs_me', JSON.stringify(me)); } catch(_){}
    // Перерисовать profAv + hAvatar
    if (typeof loadMyProfile === 'function') loadMyProfile();
    const ha = document.getElementById('hAvatar');
    if (ha) { ha.innerHTML = avaInner(me); ha.style.background = 'transparent'; }
  } catch(e) {
    if (el) el.innerHTML = prev;
    alert('Не удалось загрузить: ' + (e.message || e));
  } finally {
    input.value = '';
  }
}

async function onProfAvRemove(){
  if (!confirm('Убрать аватарку?')) return;
  try {
    const r = await fetch('/api/soc/me/avatar', {
      method: 'DELETE',
      headers: socialAuthHeaders({ 'X-Ghost-Web': '1' }),
      credentials: 'include',
    });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    me.avatar_url = null;
    try { localStorage.setItem('gs_me', JSON.stringify(me)); } catch(_){}
    if (typeof loadMyProfile === 'function') loadMyProfile();
    const ha = document.getElementById('hAvatar');
    if (ha) { ha.innerHTML = avaInner(me); ha.style.background = ''; }
  } catch(e) {
    alert('Не удалось убрать: ' + (e.message || e));
  }
}

function openProfAvLightbox(url, title, editable){
  let lb = document.getElementById('profAvLb');
  if (!lb){
    lb = document.createElement('div');
    lb.id = 'profAvLb';
    lb.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.92);backdrop-filter:blur(10px);display:flex;align-items:center;justify-content:center;cursor:zoom-out;';
    lb.innerHTML = `
      <button style="position:absolute;top:18px;right:18px;width:42px;height:42px;border-radius:50%;border:none;background:rgba(255,255,255,0.15);color:#fff;font-size:18px;cursor:pointer;" onclick="closeProfAvLb()">×</button>
      <button id="profAvLbEdit" style="position:absolute;top:18px;right:70px;width:42px;height:42px;border-radius:50%;border:none;background:rgba(255,255,255,0.15);color:#fff;font-size:14px;cursor:pointer;display:none;" onclick="event.stopPropagation();document.getElementById('profAvFile').click();closeProfAvLb()" title="Сменить"><i class="fa-solid fa-camera"></i></button>
      <img id="profAvLbImg" src="" style="max-width:92vw;max-height:85vh;border-radius:12px;cursor:default;" onclick="event.stopPropagation()">
      <div id="profAvLbTitle" style="position:absolute;bottom:24px;left:50%;transform:translateX(-50%);color:#fff;font-size:15px;font-weight:600;"></div>`;
    lb.addEventListener('click', (e) => { if (e.target === lb) closeProfAvLb(); });
    document.body.appendChild(lb);
  }
  document.getElementById('profAvLbImg').src = url;
  document.getElementById('profAvLbTitle').textContent = title || '';
  document.getElementById('profAvLbEdit').style.display = editable ? '' : 'none';
  lb.style.display = 'flex';
}

function closeProfAvLb(){
  const lb = document.getElementById('profAvLb');
  if (lb) lb.style.display = 'none';
}


/* Фрагмент GhostSocial: gsProfileRenderCard и помощники, скопированы без изменений. */
function gsProfileData(input) {
  if (!input || typeof input !== 'object') return {};
  return Object.assign({}, input.profile && typeof input.profile === 'object' ? input.profile : {},
    input.user && typeof input.user === 'object' ? input.user : {}, input);
}

function gsProfileText(value) {
  if (value == null) return '';
  if (typeof value === 'object') return String(value.text || value.label || value.status || '');
  return String(value);
}

function gsProfileMetric(data, topKeys, statKeys) {
  for (const key of topKeys) {
    const value = data[key];
    if (value != null && value !== '' && Number.isFinite(Number(value))) return value;
  }
  const stats = Object.assign({}, data.social_stats || {}, data.counters || {}, data.stats || {});
  for (const key of statKeys) {
    const value = stats[key];
    if (value == null || value === '') continue;
    if (Array.isArray(value)) return value.length;
    if (Number.isFinite(Number(value))) return value;
  }
  return null;
}

function gsProfileCount(value) {
  if (value == null || value === '') return '—';
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? String(Math.floor(number)) : '—';
}

function gsProfileCreatedDate(value) {
  const raw = gsProfileText(value).trim();
  if (!raw) return null;
  const iso = /(?:z|[+-]\d{2}:?\d{2})$/i.test(raw) ? raw : raw.replace(' ', 'T') + 'Z';
  const date = new Date(iso);
  return isNaN(date.getTime()) ? null : date;
}

function gsProfileRenderCreated(prefix, value) {
  const box = document.getElementById(prefix + 'Created');
  if (!box) return;
  const text = document.getElementById(prefix + 'CreatedText');
  const date = gsProfileCreatedDate(value);
  if (!date) {
    box.hidden = true;
    if (text) text.textContent = '';
    box.removeAttribute('title');
    return;
  }
  const label = new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'long', year: 'numeric' })
    .format(date).replace(' г.', '');
  const exact = new Intl.DateTimeFormat('ru-RU', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(date);
  if (text) text.textContent = 'Присоединился ' + label;
  box.title = 'Дата регистрации: ' + exact;
  box.hidden = false;
}

function gsProfileSetOptional(prefix, suffix, value) {
  const element = document.getElementById(prefix + suffix);
  if (!element) return;
  const text = gsProfileText(value).trim();
  element.textContent = text;
  element.hidden = !text;
}

function gsProfileRenderCard(prefix, input, fallbackUsername) {
  const data = gsProfileData(input);
  const username = String(data.username || data.gc_username || fallbackUsername || '').trim().replace(/^@/, '');
  const displayName = String(data.display_name || data.name || username || 'Пользователь').trim() || username || 'Пользователь';
  const avatar = gsProfileSetAvatar(document.getElementById(prefix + 'Av'), data, displayName);
  const name = document.getElementById(prefix + 'Name');
  if (name) name.innerHTML = esc(displayName) + userBadgesHTML(data);
  const user = document.getElementById(prefix + 'User');
  if (user) user.textContent = username ? '@' + username : '';
  const userMeta = document.getElementById(prefix + 'UserMeta');
  if (userMeta) userMeta.textContent = username ? '@' + username : '';
  gsProfileRenderBanner(prefix, data);
  try { gsProfileRenderMediaBanner(prefix, data); } catch (bannerError) { console.error('[GhostSocial] Banner mode switch failed; retaining gradient:', bannerError); const gn=document.getElementById(prefix+'Banner'); if(gn){gn.classList.remove('gs-banner-mode-media','gs-banner-media-loaded'); gn.removeAttribute('aria-hidden');} }
  gsProfileRenderBadges(prefix, data);
  gsProfileSetOptional(prefix, 'Bio', data.bio || data.about || data.about_me || data.description);
  gsProfileRenderCreated(prefix, data.created_at);
  renderDailyStatus(prefix + 'Status', gsProfileText(data.daily_status || data.status));
  const reputation = data.reputation_score != null ? data.reputation_score :
    (data.reputation && typeof data.reputation === 'object' ? data.reputation.score : data.reputation);
  renderReputation(prefix + 'Reputation', reputation, data.reputation_band || (data.reputation && data.reputation.band));
  const accountId = data.user_id != null ? data.user_id : data.id;
  const currentUsername = typeof me !== 'undefined' && me
    ? String(me.username || '').trim().replace(/^@/, '').toLowerCase() : '';
  const isOwnProfile = prefix === 'prof' || data.is_me === true ||
    (currentUsername !== '' && currentUsername === username.toLowerCase());
  const showAccountId = isOwnProfile && accountId != null;
  const idElement = document.getElementById(prefix + 'Id');
  const idValueElement = document.getElementById(prefix + 'IdValue');
  if (idValueElement) idValueElement.textContent = showAccountId ? String(accountId) : '';
  if (idElement) idElement.hidden = !showAccountId;
  const followersToday = gsProfileMetric(data, ['followers_added_today', 'new_followers_today', 'followers_today'], ['followers_added_today', 'new_followers_today', 'followers_today']);
  const todayElement = document.getElementById(prefix + 'FollowersToday');
  if (todayElement) {
    todayElement.textContent = followersToday == null ? '' : '+' + gsProfileCount(followersToday) + ' сегодня';
    todayElement.hidden = followersToday == null;
  }
  const stats = [
    [prefix === 'fp' ? 'fpPosts' : 'sPosts', ['posts_count', 'publications_count', 'total_posts'], ['posts_count', 'posts', 'publications', 'posts_total']],
    [prefix === 'fp' ? 'fpFollowers' : 'sFollowers', ['followers_count'], ['followers_count', 'followers', 'subscribers_count']],
    [prefix === 'fp' ? 'fpFollowing' : 'sFollowing', ['following_count'], ['following_count', 'following', 'subscriptions_count']],
    [prefix === 'fp' ? 'fpReceived' : 'sReceived', ['likes_received', 'likes_count'], ['likes_received', 'likes_count', 'likes', 'received_likes']]
  ];
  stats.forEach(([id, topKeys, statKeys]) => {
    const element = document.getElementById(id);
    if (element) element.textContent = gsProfileCount(gsProfileMetric(data, topKeys, statKeys));
  });
  gsProfileSetMusic(prefix, data);
  if (prefix === 'fp') {
    const avatarElement = document.getElementById('fpAv');
    if (avatarElement) avatarElement.onclick = avatar ? (() => openProfAvLightbox(avatar, displayName, !!data.is_me)) : null;
  }
}

function renderDailyStatus(elId, text) {
  const el = document.getElementById(elId);
  if (!el) return;
  const value = String(text || '').trim();
  el.hidden = !value;
  if (el.classList.contains('gs-profile-status')) {
    el.style.removeProperty('display');
    el.setAttribute('aria-label', value ? 'Статус: ' + value : 'Статус');
  } else {
    el.style.display = value ? 'block' : 'none';
  }
  const valueEl = el.querySelector('.gs-profile-status-value');
  if (valueEl) valueEl.textContent = value;
  else el.textContent = value;
}

function renderReputation(elId, score, band) {
  const el = document.getElementById(elId);
  if (!el) return;
  if (score === undefined || score === null) { el.style.display = 'none'; return; }
  const b = band || (score < 30 ? 'low' : (score < 70 ? 'mid' : 'good'));
  const icon = b === 'good' ? 'shield-halved' : (b === 'low' ? 'triangle-exclamation' : 'shield');
  const label = b === 'good' ? 'хорошая репутация' : (b === 'low' ? 'низкая репутация' : 'репутация');
  el.className = 'rep-badge rep-' + b;
  el.style.display = 'inline-flex';
  el.innerHTML = `<i class="fa-solid fa-${icon}"></i> ${label} · ${score}/100`;
}


  // ── Обвязка GhostID вокруг скопированного кода ────

  var me = null;

  function socialAuthHeaders(extra) {
    var token = store.currentToken();
    var headers = Object.assign({ Accept: 'application/json', 'X-Ghost-Web': '1' }, extra || {});
    if (token) headers.Authorization = 'Bearer ' + token;
    return headers;
  }

  function v2Loading() { return ''; }

  function loadMyProfile() { render(); }

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

  function setPlayIcon(playing) {
    var icon = els.musicPlay && els.musicPlay.querySelector('[data-music-icon]');
    if (icon) icon.className = playing ? 'fa-solid fa-pause' : 'fa-solid fa-play';
  }

  function setMusicCover(url) {
    if (!els.musicCover) return;
    els.musicCover.hidden = !url;
    if (url) els.musicCover.src = url;
    else els.musicCover.removeAttribute('src');
  }

  /** Карточка профиля: всё рисует скопированный код GhostSocial. */
  function applyProfileCard(data) {
    me = data || {};
    gsProfileRenderCard('prof', me, me.username);
  }

  /** Музыка карточки: рисуем своим плеером, разметка и классы — соцсети. */
  function gsProfileSetMusic(prefix, data) {
    var raw = data.profile_music || data.current_music || data.music || data.track;
    var tracks = Array.isArray(raw) ? raw : (raw && typeof raw === 'object' ? [raw] : []);
    paintMusic(tracks);
    var adBanner = document.getElementById(prefix + 'Banner');
    if (adBanner && els.music) {
      var design = adBanner._gsBannerDesign;
      if (design) {
        els.music.style.backgroundColor = design.color;
        els.music.style.backgroundImage = design.image || 'none';
      }
    }
  }

function esc(s) { return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;'); }

function userBadgesHTML(u){
  if (!u) return '';
  var out = '';
  // временно оставлена только верификация — роль/премиум ждут финального визуала
  // if (u.is_admin) out += '<i class="fa-solid fa-crown ub-admin" title="Администратор"></i>';
  // else if (u.is_moderator) out += '<i class="fa-solid fa-shield ub-mod" title="Модератор"></i>';
  if (u.is_verified) out += '<span class="ub-verified" title="Верифицирован"><i class="fa-solid fa-check"></i></span>';
  // if (u.is_premium) out += '<i class="fa-solid fa-star ub-premium" title="Премиум"></i>';
  return out ? '<span class="user-badges">'+out+'</span>' : '';
}

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


  function stopMusic() {
    if (els.audio) els.audio.pause();
    if (els.music) els.music.classList.remove('is-playing');
    if (els.musicPlay) {
      els.musicPlay.setAttribute('aria-pressed', 'false');
      els.musicPlay.setAttribute('aria-label', 'Включить музыку профиля');
    }
    setPlayIcon(false);
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
    setMusicCover(cover);

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
      setMusicCover(cover);
      els.audio.src = audioUrl;
      paintMusicProgress(0, Number(track.duration_ms || 0) / 1000);
    }
    els.audio.play().then(function () {
      els.music.classList.add('is-playing');
      els.musicPlay.setAttribute('aria-pressed', 'true');
      els.musicPlay.setAttribute('aria-label', 'Выключить музыку профиля');
      setPlayIcon(true);
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

    applyProfileCard(details.raw || {
      id: profile.id, username: profile.username,
      display_name: profile.display_name, avatar_url: profile.avatar_url
    });
    if (els.activeBalance) {
      var balance = normalBalance(details.balance);
      els.activeBalance.hidden = balance == null;
      els.activeBalance.textContent = balance == null ? '' : balance + ' GOST';
    }
    if (els.editActive) els.editActive.disabled = Boolean(details.expired);
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
      setPlayIcon(false);
    });
    els.audio.addEventListener('play', function () {
      if (els.music) els.music.classList.add('is-playing');
      setPlayIcon(true);
    });
  }
  if (els.add) els.add.addEventListener('click', goAddAccount);
  if (document.getElementById('profAccountsBtn')) {
    document.getElementById('profAccountsBtn').hidden = true;
  }
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

  // ── Инлайновые обработчики разметки соцсети ──────

  window.onProfAvClick = onProfAvClick;
  window.onProfAvFileChosen = onProfAvFileChosen;
  window.onProfAvRemove = onProfAvRemove;
  window.openProfAvLightbox = openProfAvLightbox;
  window.closeProfAvLb = closeProfAvLb;
  window.openEditProfile = function () {
    var entry = activeEntry();
    if (entry) openEditor(entry);
  };
  window.gsAccountsToggle = function (event) {
    if (event) event.preventDefault();
    if (els.listWrap) els.listWrap.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };
  window.gsAccountsAddAccount = goAddAccount;
  window.openStatusModal = function () {
    var entry = activeEntry();
    if (entry) openEditor(entry);
  };

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
