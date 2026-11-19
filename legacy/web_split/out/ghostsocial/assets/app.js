const API = '/api/soc';
let token = localStorage.getItem('gs_token');
let me = null;
try { me = JSON.parse(localStorage.getItem('gs_me') || 'null'); }
catch(_) { localStorage.removeItem('gs_me'); me = null; }
let currentSort = 'new';
let seenIds = new Set();
try { seenIds = new Set(JSON.parse(localStorage.getItem('gs_seen') || '[]')); }
catch(_) { localStorage.removeItem('gs_seen'); seenIds = new Set(); }
const PAGE = 15, WIN = 30;
let feedPosts = [], feedOffset = 0, feedLoading = false, feedHasMore = true, renderStart = 0;
let newInterval = null;
let randomSeed = 0;
let lastSeenMaxId = 0;       // верхняя граница «прочитанного» — посты с id > этого считаются новыми
let curCommentPostId = null, commentOffset = 0;
let attachedFiles = [];
let currentPickType = null;
let viewerUrl = '', viewerEl = null;
let ctxUrl = '';

// ── Utils ──────────────────────────────────────────────────────────────────────

function esc(s) { return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;'); }
// jsAttr: безопасная JS-литерал внутри HTML onclick. esc(JSON.stringify(v)) даёт
// строку которая корректно работает и в HTML-атрибуте и в JS. Используй вместо
// `'${esc(s)}'` — там HTML декодит &#39; обратно в ' → XSS.
function jsAttr(v){return esc(JSON.stringify(v == null ? null : String(v)));}

function highlightText(raw, query) {
  raw = String(raw == null ? '' : raw);
  if (typeof query !== 'string' || !query.trim()) return esc(raw);
  const q = query.trim(), lowRaw = raw.toLowerCase(), lowQ = q.toLowerCase();
  let out = '', i = 0, idx;
  while ((idx = lowRaw.indexOf(lowQ, i)) !== -1) {
    out += esc(raw.slice(i, idx)) + '<mark class="hl">' + esc(raw.slice(idx, idx + q.length)) + '</mark>';
    i = idx + q.length;
  }
  return out + esc(raw.slice(i));
}

function ini(n) { return n ? n[0].toUpperCase() : '?'; }

function ago(ts) {
  const d = new Date(ts.includes('Z') || ts.includes('+') ? ts : ts + 'Z');
  const s = Math.floor((Date.now() - d) / 1000);
  if (s < 60) return 'только что';
  if (s < 3600) return Math.floor(s / 60) + ' мин';
  if (s < 86400) return Math.floor(s / 3600) + ' ч';
  return Math.floor(s / 86400) + ' д';
}

function fmtTime(s) { const m = Math.floor(s / 60); return `${m}:${String(Math.floor(s % 60)).padStart(2, '0')}`; }

function showToast(msg) {
  const t = document.getElementById('toast');
  t.textContent = msg; t.classList.add('show');
  setTimeout(() => t.classList.remove('show'), 2200);
}

async function api(path, method = 'GET', body = null, opts2 = {}) {
  const h = { 'Content-Type': 'application/json' };
  if (token) h['Authorization'] = 'Bearer ' + token;
  // Тайм-аут (по умолчанию 20с). Для постов с медиа/миниск — поднимаем через opts2.timeout.
  const timeout = opts2.timeout || 20000;
  const ctrl = new AbortController();
  const tid = setTimeout(() => ctrl.abort(), timeout);
  const opts = { method, headers: h, signal: ctrl.signal };
  if (body) opts.body = JSON.stringify(body);
  let r;
  try {
    r = await fetch(API + path, opts);
  } catch(e) {
    if (e.name === 'AbortError' || /aborted/i.test(e.message || '')) {
      const err = new Error(`Сервер не ответил за ${Math.round(timeout/1000)}с. Попробуй ещё или проверь соединение.`);
      err.timeout = true; throw err;
    }
    throw e;
  } finally { clearTimeout(tid); }
  if (!r.ok) {
    const text = await r.text();
    let msg = text;
    try { msg = JSON.parse(text).detail || text; } catch(e) {}
    const err = new Error(msg); err.status = r.status; throw err;
  }
  return r.json();
}

function closeModal(id) { document.getElementById(id).classList.remove('open'); }
document.querySelectorAll('.modal-overlay').forEach(el => {
  el.addEventListener('click', function(e) { if (e.target === this) this.classList.remove('open'); });
});

// ── Auth screen ────────────────────────────────────────────────────────────────

function showAuthScreen() {
  document.getElementById('authScreen').style.display = 'flex';
  document.getElementById('appHeader').style.display = 'none';
  document.getElementById('appMain').style.display = 'none';
  document.getElementById('appNav').style.display = 'none';
  document.getElementById('dtSideLeft').style.display = 'none';
  document.body.style.paddingTop = '0';
  document.body.style.paddingBottom = '0';
  document.body.classList.remove('feed-mode');
}

function showApp() {
  document.getElementById('authScreen').style.display = 'none';
  document.getElementById('appHeader').style.display = '';
  document.getElementById('appMain').style.display = 'block';
  // На десктопе показываем только сайдбар, нижний nav скрываем через CSS @media
  document.getElementById('appNav').style.display = 'flex';
  document.getElementById('dtSideLeft').style.display = ''; // позволяет CSS @media решать
  document.body.style.paddingTop = ''; // переменная --header-h CSS возьмёт верх
  document.body.style.paddingBottom = 'calc(68px + env(safe-area-inset-bottom))';
  if (me) document.getElementById('hAvatar').textContent = ini(me.display_name || me.username);
  document.body.classList.toggle('guest-mode', isGuest());
  // Gost-pill в шапке скрываем для гостей (у них нет кошелька), показываем для всех остальных
  const gp = document.getElementById('gostPill');
  if (gp) gp.style.display = isGuest() ? 'none' : '';
  // Тихо подтянуть баланс при старте — чтобы в pill сразу был актуал, а не «0»
  if (!isGuest()) {
    api('/wallet').then(w => updateGostPill(w.balance.gost || 0)).catch(() => {});
    // Ежедневный статус — если просрочен/не поставлен → форсим модал
    checkDailyStatus();
    // Кэш моих репостов (для кнопки «репост» в share-sheet)
    api('/me/reposts/ids').then(ids => { window._myReposts = new Set(ids || []); }).catch(() => {});
  }
}

// ── Ежедневный статус (обязательный) ─────────────────────────────────────────
async function checkDailyStatus() {
  try {
    const s = await api('/status/my');
    if (s && s.must_set) openStatusModal();
  } catch(e) { /* при ошибке не блокируем — следующий заход проверит */ }
}

function openStatusModal() {
  // Если уже открыт — не дублируем
  if (document.getElementById('dailyStatusModal')) return;
  const overlay = document.createElement('div');
  overlay.id = 'dailyStatusModal';
  overlay.style.cssText = 'position:fixed;inset:0;z-index:10000;background:rgba(2,6,23,0.85);backdrop-filter:blur(20px);display:flex;align-items:center;justify-content:center;padding:20px;';
  overlay.innerHTML = `
    <div style="background:rgba(15,23,42,0.95);border:1px solid rgba(168,85,247,0.30);border-radius:18px;padding:24px;max-width:420px;width:100%;">
      <div style="font-size:11px;font-weight:800;letter-spacing:2px;text-transform:uppercase;color:var(--primary);margin-bottom:6px;">Ежедневный статус</div>
      <h2 style="font-size:22px;font-weight:800;margin-bottom:8px;color:var(--text);">Что у тебя сейчас?</h2>
      <p style="font-size:13px;color:var(--sub);line-height:1.6;margin-bottom:16px;">Одна строка, как день. Видна всем в твоём профиле. Сбрасывается через 24 часа — придётся поставить новую.</p>
      <textarea id="dailyStatusInput" placeholder="например: пилю репосты для GhostSocial" maxlength="140" rows="2" style="width:100%;padding:12px;background:rgba(15,23,42,0.6);border:1px solid rgba(255,255,255,0.08);border-radius:12px;color:var(--text);font-size:14px;font-family:inherit;resize:none;outline:none;line-height:1.5;"></textarea>
      <div style="display:flex;justify-content:space-between;align-items:center;margin-top:8px;margin-bottom:14px;">
        <span id="dailyStatusCount" style="font-size:11px;color:var(--sub);">0 / 140</span>
        <span id="dailyStatusErr" style="font-size:11px;color:#f87171;"></span>
      </div>
      <button id="dailyStatusBtn" class="auth-btn" style="width:100%;" disabled>Опубликовать</button>
    </div>
  `;
  document.body.appendChild(overlay);
  const ta = document.getElementById('dailyStatusInput');
  const cnt = document.getElementById('dailyStatusCount');
  const btn = document.getElementById('dailyStatusBtn');
  ta.focus();
  ta.addEventListener('input', () => {
    const v = ta.value.trim();
    cnt.textContent = `${ta.value.length} / 140`;
    btn.disabled = v.length === 0;
  });
  btn.addEventListener('click', async () => {
    const v = ta.value.trim();
    if (!v) return;
    btn.disabled = true; btn.textContent = '...';
    try {
      await api('/status/set', 'POST', { text: v });
      overlay.remove();
    } catch(e) {
      document.getElementById('dailyStatusErr').textContent = e.message || 'Ошибка';
      btn.disabled = false; btn.textContent = 'Опубликовать';
    }
  });
}

function switchTab(tab) {
  document.getElementById('loginForm').style.display = tab === 'login' ? 'block' : 'none';
  document.getElementById('regForm').style.display = tab === 'reg' ? 'block' : 'none';
  document.getElementById('tabLogin').classList.toggle('active', tab === 'login');
  document.getElementById('tabReg').classList.toggle('active', tab === 'reg');
  document.getElementById('loginError').textContent = '';
  document.getElementById('regError').textContent = '';
}

async function doLogin() {
  const btn = document.getElementById('loginBtn');
  const errEl = document.getElementById('loginError');
  const username = document.getElementById('loginUsername').value.trim();
  const password = document.getElementById('loginPassword').value;
  errEl.textContent = '';
  if (!username || !password) { errEl.textContent = 'Заполните все поля'; return; }
  btn.disabled = true; btn.textContent = '...';
  try {
    const d = await api('/login', 'POST', { username, password });
    token = d.token; me = d;
    localStorage.setItem('gs_token', token); setSsoCookie(token);
    localStorage.setItem('gs_me', JSON.stringify(me));
    showApp();
    document.body.classList.add('feed-mode');
    startPolling();
  } catch(e) {
    errEl.textContent = e.message || 'Ошибка входа';
  }
  btn.disabled = false; btn.textContent = 'Войти';
}

async function doRegister() {
  const btn = document.getElementById('regBtn');
  const errEl = document.getElementById('regError');
  const username = document.getElementById('regUsername').value.trim();
  const display_name = document.getElementById('regName').value.trim();
  const password = document.getElementById('regPassword').value;
  const confirm = document.getElementById('regPasswordConfirm').value;
  const age18 = !!document.getElementById('regAge18').checked;
  errEl.textContent = '';
  if (!username || !display_name || !password || !confirm) { errEl.textContent = 'Заполните все поля'; return; }
  if (password !== confirm) { errEl.textContent = 'Пароли не совпадают'; return; }
  if (!age18) { errEl.textContent = 'Подтвердите, что вам исполнилось 18 лет'; return; }
  btn.disabled = true; btn.textContent = '...';
  // Реф: из URL или localStorage (сохранил лендинг)
  let ref = (new URLSearchParams(location.search)).get('ref') || localStorage.getItem('gs_ref') || null;
  if (ref) ref = ref.trim().replace(/^@/, '').toLowerCase();
  try {
    const d = await api('/register', 'POST', { username, display_name, password, ref: ref || undefined, age_18_confirm: true });
    if (ref) localStorage.removeItem('gs_ref');
    token = d.token; me = d;
    localStorage.setItem('gs_token', token); setSsoCookie(token);
    localStorage.setItem('gs_me', JSON.stringify(me));
    showApp();
    document.body.classList.add('feed-mode');
    startPolling();
  } catch(e) {
    errEl.textContent = e.message || 'Ошибка регистрации';
  }
  btn.disabled = false; btn.textContent = 'Зарегистрироваться';
}

async function doGuest() {
  const btn = document.getElementById('guestBtn');
  btn.disabled = true; btn.textContent = '...';
  try {
    const d = await api('/guest', 'POST');
    token = d.token; me = d;
    localStorage.setItem('gs_token', token); setSsoCookie(token);
    localStorage.setItem('gs_me', JSON.stringify(me));
    showApp();
    document.body.classList.add('feed-mode');
    startPolling();
  } catch(e) {
    document.getElementById('loginError').textContent = e.message || 'Ошибка';
  }
  btn.disabled = false; btn.textContent = 'Войти как гость';
}

function isGuest() { return me && me.is_guest === true; }

// SSO cookie — общий для GhostEcos (используется шопом и главной)
function setSsoCookie(t) {
  // SameSite=Lax + Secure (только на https — иначе браузер дропает cookie молча).
  const secure = location.protocol === 'https:' ? '; Secure' : '';
  document.cookie = `gs_token=${encodeURIComponent(t)}; path=/; max-age=31536000; SameSite=Lax${secure}`;
}
function clearSsoCookie() {
  const secure = location.protocol === 'https:' ? '; Secure' : '';
  document.cookie = `gs_token=; path=/; max-age=0; SameSite=Lax${secure}`;
}

function startPolling() {
  loadFeed();
  startNewCheck();
  startCountsUpdate();
  if (!isGuest()) startNotifCheck(); // у гостя нет уведомлений
  RT.connect();
  maybeShowInstallPrompt();
}

// ── МИНИСКИ ────────────────────────────────────────────────────────────────
const MINISKA_TTL_HOURS = 48;
function miniskaTTL(createdAt) {
  const ts = (createdAt || '').includes('Z') || (createdAt || '').includes('+') ? createdAt : createdAt + 'Z';
  const created = new Date(ts).getTime();
  const expireAt = created + MINISKA_TTL_HOURS * 3600 * 1000;
  const left = expireAt - Date.now();
  if (left <= 0) return { text: 'исчезает…', cls: 'danger' };
  const hours = Math.floor(left / 3600000);
  const mins = Math.floor((left % 3600000) / 60000);
  let text;
  if (hours >= 1) text = hours + ' ч';
  else text = mins + ' мин';
  text = 'осталось ' + text;
  let cls = '';
  if (hours < 1) cls = 'danger';
  else if (hours < 6) cls = 'warn';
  return { text, cls };
}

let _mskItems = [];
let _mskLoading = false;
let _mskHasMore = true;
let _mskOffset = 0;
let _mskObserver = null;

async function loadMinisky(initial=true) {
  const feed = document.getElementById('mskFeed');
  if (initial) {
    _mskItems = []; _mskOffset = 0; _mskHasMore = true;
    feed.innerHTML = '<div class="msk-empty"><div class="spinner"></div><p style="margin-top:14px;">Загружаем миниски…</p></div>';
  }
  if (_mskLoading || !_mskHasMore) return;
  _mskLoading = true;
  try {
    const exclude = _mskItems.map(x => x.id).slice(-200).join(',');
    const data = await api(`/miniska/feed?offset=${_mskOffset}&limit=10${exclude ? '&exclude='+encodeURIComponent(exclude) : ''}`);
    _mskOffset += data.length;
    if (data.length < 10) _mskHasMore = false;
    _mskItems = initial ? data : [..._mskItems, ...data];
    renderMinisky();
  } catch(e) {
    if (initial) feed.innerHTML = '<div class="msk-empty"><i class="fa-solid fa-triangle-exclamation"></i><h3>Не удалось загрузить</h3></div>';
  }
  _mskLoading = false;
}

function renderMinisky() {
  const feed = document.getElementById('mskFeed');
  if (!_mskItems.length) {
    feed.innerHTML = `<div class="msk-empty">
      <i class="fa-solid fa-video"></i>
      <h3>Миниски ещё пустые</h3>
      <p>Будь первым — загрузи короткое видео по кнопке +</p>
    </div>`;
    return;
  }
  feed.innerHTML = _mskItems.map(p => {
    const video = (p.media || []).find(m => m.type === 'video');
    if (!video) return '';
    const your = p.reactions && p.reactions.your_emoji;
    const reactsTotal = (p.reactions && p.reactions.total) || 0;
    const ttl = miniskaTTL(p.created_at);
    return `<div class="msk-card" data-id="${p.id}">
      <div class="msk-progress"><div class="msk-progress-fill"></div></div>
      <div class="msk-ttl ${ttl.cls}" title="Миниски хранятся 48 часов"><i class="fa-regular fa-clock"></i>${ttl.text}</div>
      <video src="${esc(video.url)}" preload="metadata" playsinline loop muted></video>
      <div class="msk-play-overlay"><i class="fa-solid fa-play"></i></div>
      <div class="msk-overlay">
        <div class="msk-info">
          <div class="author" onclick="event.stopPropagation();openFullProfile(${jsAttr(p.username)})">
            <div class="av">${ini(p.display_name)}</div>
            <div>
              <div class="name">${esc(p.display_name)}</div>
              <div class="un">@${esc(p.username)}</div>
            </div>
          </div>
          <div class="caption">${linkifyContent(p.content || '', '')}</div>
        </div>
      </div>
      <div class="msk-side">
        <button class="${your === 'heart' ? 'liked' : ''}" onclick="event.stopPropagation();mskReact(${p.id})">
          <i class="fa-${your === 'heart' ? 'solid' : 'regular'} fa-heart"></i>
        </button>
        <div class="lbl">${reactsTotal}</div>
        <button onclick="event.stopPropagation();openComments(${p.id})"><i class="fa-regular fa-comment"></i></button>
        <div class="lbl">${p.comments_count || 0}</div>
        <button onclick="event.stopPropagation();sharePost(${p.id})"><i class="fa-solid fa-share-nodes"></i></button>
        ${me && p.user_id === me.id ? `<button onclick="event.stopPropagation();deletePost(${p.id})" title="Удалить"><i class="fa-solid fa-trash-can"></i></button>` : ''}
      </div>
    </div>`;
  }).join('');
  setupMiniskyAutoplay();
  setupMiniskyTaps();
}

function setupMiniskyAutoplay() {
  if (_mskObserver) _mskObserver.disconnect();
  _mskObserver = new IntersectionObserver(entries => {
    entries.forEach(e => {
      const v = e.target.querySelector('video');
      if (!v) return;
      if (e.intersectionRatio > 0.6) {
        v.muted = false;
        v.play().catch(() => { v.muted = true; v.play().catch(()=>{}); });
        // Дозагрузка
        const card = e.target;
        const allCards = [...document.querySelectorAll('.msk-card')];
        const idx = allCards.indexOf(card);
        if (idx >= allCards.length - 2 && _mskHasMore && !_mskLoading) loadMinisky(false);
      } else {
        v.pause();
      }
    });
  }, { root: document.getElementById('mskFeed'), threshold: [0, 0.6, 1] });
  document.querySelectorAll('.msk-card').forEach(c => _mskObserver.observe(c));
  // Прогресс-бар
  document.querySelectorAll('.msk-card').forEach(card => {
    const v = card.querySelector('video');
    const fill = card.querySelector('.msk-progress-fill');
    if (v && fill && !v._progBound) {
      v._progBound = 1;
      v.addEventListener('timeupdate', () => {
        if (v.duration) fill.style.width = (v.currentTime / v.duration * 100) + '%';
      });
    }
  });
}

function setupMiniskyTaps() {
  document.querySelectorAll('.msk-card').forEach(card => {
    if (card._tapBound) return; card._tapBound = 1;
    card.addEventListener('click', e => {
      if (e.target.closest('button, a, .author')) return;
      const v = card.querySelector('video');
      const ov = card.querySelector('.msk-play-overlay');
      if (!v) return;
      if (v.paused) { v.play(); ov.classList.remove('show'); }
      else { v.pause(); ov.classList.add('show'); }
    });
  });
}

function stopMinisky() {
  document.querySelectorAll('.msk-card video').forEach(v => v.pause());
  if (_mskObserver) { _mskObserver.disconnect(); _mskObserver = null; }
}

async function mskReact(postId) {
  if (isGuest()) { guestBlock(); return; }
  const p = _mskItems.find(x => x.id === postId);
  if (!p) return;
  const cur = p.reactions && p.reactions.your_emoji;
  const next = cur === 'heart' ? null : 'heart';
  try {
    const r = await api(`/react/${postId}`, 'POST', { emoji: next });
    p.reactions = r;
    Algo.onReact(p, !!next);
    // Точечно обновляем UI этой карточки, не пересоздавая <video>
    const card = document.querySelector(`.msk-card[data-id="${postId}"]`);
    if (card) {
      const likeBtn = card.querySelector('.msk-side button');
      const likeIcon = likeBtn && likeBtn.querySelector('i');
      const likeLbl = card.querySelectorAll('.msk-side .lbl')[0];
      if (likeBtn) likeBtn.classList.toggle('liked', !!next);
      if (likeIcon) likeIcon.className = `fa-${next ? 'solid' : 'regular'} fa-heart`;
      if (likeLbl) likeLbl.textContent = (r.total || 0);
    }
    refreshWallet();  // если автор онлайн в др. вкладке — обновится у него; нам не повредит
  } catch(e) {}
}

// Динамические хэштеги для миниски (3..10)
const MSK_TAG_MIN = 3, MSK_TAG_MAX = 10;
let _mskTagValues = ['', '', ''];

function renderMiniskaTags(){
  const list = document.getElementById('miniskaTagsList');
  if (!list) return;
  list.innerHTML = _mskTagValues.map((v, i) => {
    const removable = i >= MSK_TAG_MIN;
    return `
    <div class="msk-tag-wrap${removable ? ' removable' : ''}">
      <input class="msk-tag-input" data-msk-tag-idx="${i}" placeholder="#тег${i+1}" maxlength="30" value="${esc(v)}">
      ${removable ? `<button type="button" class="msk-tag-x" onclick="removeMiniskaTag(${i})" title="Убрать"><i class="fa-solid fa-xmark"></i></button>` : ''}
    </div>`;
  }).join('');
  // Привяжем input handler заново
  list.querySelectorAll('input[data-msk-tag-idx]').forEach(el => {
    el.addEventListener('input', () => {
      const i = +el.dataset.mskTagIdx;
      el.value = el.value.replace(/^#+/, '').replace(/[^a-zа-я0-9_]/giu, '');
      _mskTagValues[i] = el.value;
      updateMiniskaTagsCount();
      updatePubBtn();
    });
  });
  updateMiniskaTagsCount();
  // Видимость кнопки "Добавить"
  const addBtn = document.getElementById('miniskaAddTagBtn');
  if (addBtn) addBtn.style.display = _mskTagValues.length >= MSK_TAG_MAX ? 'none' : '';
}

function updateMiniskaTagsCount(){
  const cnt = _mskTagValues.filter(v => v.trim().length >= 2).length;
  const el = document.getElementById('miniskaTagsCount');
  if (el) el.textContent = `${cnt}/${MSK_TAG_MAX}`;
}

function addMiniskaTag(){
  if (_mskTagValues.length >= MSK_TAG_MAX) return;
  _mskTagValues.push('');
  renderMiniskaTags();
  updatePubBtn();
}

function removeMiniskaTag(idx){
  if (_mskTagValues.length <= MSK_TAG_MIN) return;
  _mskTagValues.splice(idx, 1);
  renderMiniskaTags();
  updatePubBtn();
}

function resetMiniskaTags(){
  _mskTagValues = ['', '', ''];
  renderMiniskaTags();
}

// ── Тумблер «Сделать миниской» в create-card ──
function onMiniskaToggle(on) {
  const tagsBlock = document.getElementById('miniskaTagsBlock');
  const pollBtn = document.getElementById('pollBtn');
  const postText = document.getElementById('postText');
  tagsBlock.style.display = on ? 'block' : 'none';
  if (pollBtn) pollBtn.style.display = on ? 'none' : '';
  if (on && _pollDraft) { _pollDraft = null; renderPollEditor(); }
  postText.placeholder = on ? 'Подпись к миниске (необязательно)' : 'Что на уме?';
  if (on && attachedFiles.length) {
    const firstVideo = attachedFiles.find(f => f.type === 'video');
    attachedFiles = firstVideo ? [firstVideo] : [];
    renderMediaPreview();
  }
  if (on) renderMiniskaTags();
  updatePubBtn();
}

// Маленькие кнопки-иконки переключают скрытые чекбоксы
function toggleNsfw() {
  const cb = document.getElementById('nsfwToggle');
  cb.checked = !cb.checked;
  cb.dispatchEvent(new Event('change'));
  refreshComposerMode();
}
function toggleMiniska() {
  const cb = document.getElementById('miniskaToggle');
  cb.checked = !cb.checked;
  onMiniskaToggle(cb.checked);
  refreshComposerMode();
}
// Подсвечивает активные иконки и показывает индикатор сверху
function refreshComposerMode() {
  const nsfw = document.getElementById('nsfwToggle').checked;
  const msk  = document.getElementById('miniskaToggle').checked;
  const nsfwBtn = document.getElementById('nsfwBtn');
  const mskBtn  = document.getElementById('miniskaBtn');
  if (nsfwBtn) nsfwBtn.classList.toggle('attached', nsfw);
  if (mskBtn)  mskBtn.classList.toggle('attached', msk);
  // Цвет NSFW-иконки красный когда активна
  if (nsfwBtn) nsfwBtn.style.color = nsfw ? '#f87171' : '';
  // Индикатор сверху
  const ind = document.getElementById('composerModeIndicator');
  if (!ind) return;
  const parts = [];
  if (msk)  parts.push(`<i class="fa-solid fa-video"></i> миниска · 48 ч`);
  if (nsfw) parts.push(`<i class="fa-solid fa-eye-slash"></i> 18+ NSFW (с блюром)`);
  if (!parts.length) { ind.style.display = 'none'; return; }
  ind.style.display = 'flex';
  ind.style.alignItems = 'center';
  ind.style.gap = '14px';
  ind.style.flexWrap = 'wrap';
  // Цвет фона: красный если NSFW, фиолетовый если только миниска
  const color = nsfw ? '#f87171' : 'var(--primary)';
  const bg = nsfw ? 'rgba(248,113,113,0.10)' : 'rgba(168,85,247,0.10)';
  const border = nsfw ? 'rgba(248,113,113,0.30)' : 'rgba(168,85,247,0.30)';
  ind.style.color = color;
  ind.style.background = bg;
  ind.style.border = '1px solid ' + border;
  ind.innerHTML = parts.join(' · ');
}

function _miniskaTags() {
  return _mskTagValues.map(v => (v || '').trim().replace(/^#+/, '')).filter(Boolean);
}
function _validateMiniska() {
  const vids = attachedFiles.filter(f => f.type === 'video');
  if (vids.length !== 1) return { ok: false, err: 'Прикрепите ровно одно видео' };
  if (attachedFiles.length > 1) return { ok: false, err: 'Миниска — только одно видео, без других файлов' };
  const tags = _miniskaTags();
  if (tags.length < MSK_TAG_MIN) return { ok: false, err: `Заполните минимум ${MSK_TAG_MIN} хэштега` };
  const re = /^[a-zа-я0-9_]{2,30}$/iu;
  for (const t of tags) {
    if (!re.test(t)) return { ok: false, err: `Тег #${t}: 2–30 символов, только буквы/цифры/_` };
  }
  if (new Set(tags.map(t => t.toLowerCase())).size !== tags.length) {
    return { ok: false, err: 'Хэштеги не должны повторяться' };
  }
  return { ok: true, tags };
}

// ── PWA install prompt (iOS Safari) ──
function isIOS(){
  const ua = navigator.userAgent || '';
  return /iPad|iPhone|iPod/.test(ua) || (ua.includes('Mac') && 'ontouchend' in document);
}
function isStandalone(){
  return window.navigator.standalone === true ||
         window.matchMedia('(display-mode: standalone)').matches;
}
function maybeShowInstallPrompt(){
  if (!isStandalone()) {
    const btn = document.getElementById('profInstallBtn');
    if (btn) btn.style.display = '';
  }
  if (isStandalone()) return;
  if (!isIOS()) return;
  if (localStorage.getItem('install_seen')) return;
  setTimeout(openInstall, 2500);
}
function openInstall(){
  const m = document.getElementById('installModal');
  if (m) m.classList.add('open');
}
function closeInstall(remember){
  const m = document.getElementById('installModal');
  if (m) m.classList.remove('open');
  if (remember) localStorage.setItem('install_seen', '1');
}

// ── Real-time через WebSocket ─────────────────────────────────────────────────
// Сервер шлёт post.new / post.delete / post.edit / post.react / post.comment / notif.new
const RT = (() => {
  let ws = null, reconnectDelay = 1000, manualClose = false, pingTimer = null;
  const URL_BASE = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/api/soc/ws';

  function url() {
    const t = localStorage.getItem('gs_token');
    return t ? `${URL_BASE}?token=${encodeURIComponent(t)}` : URL_BASE;
  }

  let policyDenied = false;  // если сервер сказал нет (cap/auth) — больше не дёргаемся
  function connect() {
    if (policyDenied) return;
    if (ws && (ws.readyState === 0 || ws.readyState === 1)) return;
    manualClose = false;
    try { ws = new WebSocket(url()); } catch(_) { scheduleReconnect(); return; }
    ws.onopen = () => {
      reconnectDelay = 1000;
      // keep-alive ping каждые 25с
      clearInterval(pingTimer);
      pingTimer = setInterval(() => { try { ws.send('ping'); } catch(_) {} }, 25000);
      // При (re)connect — синкаем баланс на случай что пока WS лежал, нам что-то начислили
      if (typeof refreshWallet === 'function') refreshWallet();
    };
    ws.onmessage = (e) => {
      if (e.data === 'pong') return;
      let m;
      try { m = JSON.parse(e.data); } catch(_) { return; }
      handle(m);
    };
    ws.onclose = (ev) => {
      clearInterval(pingTimer);
      // 1008 = policy violation (cap/auth). Не пытаемся бесконечно стучаться.
      if (ev && (ev.code === 1008 || ev.code === 4401 || ev.code === 4403)) {
        policyDenied = true; return;
      }
      if (!manualClose) scheduleReconnect();
    };
    ws.onerror = () => { try { ws.close(); } catch(_) {} };
  }

  function scheduleReconnect() {
    setTimeout(connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, 30000);
  }

  function disconnect() {
    manualClose = true;
    clearInterval(pingTimer);
    if (ws) { try { ws.close(); } catch(_) {} ws = null; }
  }

  function handle(m) {
    const t = m.type, d = m.data || {};
    if (t === 'wallet.credit') {
      console.log('[wallet.credit]', d);
      // Сервер заплюсовал нам валюту — обновляем pill и тост
      if (d.currency === 'gost') {
        // Если сервер прислал balance — обновляем сразу. Если нет — fetch для надёжности.
        if (typeof d.balance === 'number') {
          updateGostPill(d.balance);
        } else {
          refreshWallet();
        }
        const labels = {register:'welcome', daily:'дейли', post:'за пост', react:'за лайк',
                        comment:'за коммент', follow:'за подписчика'};
        const reason = labels[d.source] || d.source;
        showToast(`+${d.delta} Gost · ${reason}`);
        // Если открыт экран кошелька — перерисовать историю
        if (document.getElementById('screenWallet').classList.contains('active')) loadWallet();
      }
      return;
    }
    if (t === 'post.new') {
      const p = d.post;
      if (!p || currentSort !== 'new' || currentTag) {
        // Не в режиме «Новые» → просто покажем пилюлю
        if (currentSort === 'new') document.getElementById('newPill').classList.add('show');
        return;
      }
      if (feedPosts.find(x => x.id === p.id)) return;
      if (window.scrollY < 80) prependNew(); // потянет с сервера актуальные
      else document.getElementById('newPill').classList.add('show');
    }
    else if (t === 'post.delete') {
      const id = d.post_id;
      feedPosts = feedPosts.filter(p => p.id !== id);
      document.querySelectorAll(`.post-card[data-id="${id}"]`).forEach(el => {
        el.style.transition = 'opacity 0.3s'; el.style.opacity = '0';
        setTimeout(() => el.remove(), 300);
      });
    }
    else if (t === 'post.edit') {
      const p = d.post;
      if (!p) return;
      const idx = feedPosts.findIndex(x => x.id === p.id);
      if (idx < 0) return;
      // Сохраняем your_emoji/am_following (зависит от текущего юзера)
      p.reactions = p.reactions || {counts:{}, your_emoji:null, total:0};
      p.reactions.your_emoji = (feedPosts[idx].reactions && feedPosts[idx].reactions.your_emoji) || null;
      p.am_following = feedPosts[idx].am_following;
      feedPosts[idx] = p;
      document.querySelectorAll(`.post-card[data-id="${p.id}"]`).forEach(card => { card.outerHTML = postHTML(p); });
      attachEvents(); attachDoubleTap(); loadPreviews(); initAllAudios();
    }
    else if (t === 'post.react') {
      const id = d.post_id;
      const p = findPost(id);
      if (!p) return;
      const your = (p.reactions && p.reactions.your_emoji) || null;
      p.reactions = { counts: d.reactions.counts || {}, total: d.reactions.total || 0, your_emoji: your };
      document.querySelectorAll(`.post-card[data-id="${id}"]`).forEach(card => {
        const row = card.querySelector('[data-action="reactions-row"]');
        if (row) row.innerHTML = reactionsHTML(p);
      });
      attachEvents();
    }
    else if (t === 'post.comment') {
      const id = d.post_id;
      const p = findPost(id);
      if (p && typeof d.comments_count === 'number') {
        p.comments_count = d.comments_count;
        document.querySelectorAll(`[data-post="${id}"][data-action="comment"] .cc`).forEach(e => e.textContent = d.comments_count);
      }
      // Если открыта модалка комментов этого поста — обновим список
      if (curCommentPostId === id) {
        const m = document.getElementById('commentsModal');
        if (m && m.classList.contains('open')) { commentOffset = 0; loadComments(false); }
      }
    }
    else if (t === 'notif.new') {
      // Пинг — пересчитать бейдж
      checkNotifCount();
    }
  }

  return { connect, disconnect, handle };
})();

window.addEventListener('beforeunload', () => RT.disconnect());

function guestBlock() {
  showToast('Войдите или зарегистрируйтесь, чтобы продолжить');
}

function showGuestStub(screenId) {
  const target = screenId === 'screenProfile' ? 'screenProfile' : 'screenCreate';
  const screen = document.getElementById(target);
  const title = target === 'screenProfile' ? 'У вас нет профиля' : 'Гостям сюда нельзя';
  const text  = target === 'screenProfile'
    ? 'Вы зашли как гость. Зарегистрируйтесь или войдите в аккаунт, чтобы получить свой профиль.'
    : 'Гости не могут публиковать посты. Войдите или зарегистрируйтесь, чтобы делиться своими мыслями.';
  screen.innerHTML = `
    <div class="guest-block">
      <i class="fa-solid fa-ghost"></i>
      <h3>${title}</h3>
      <p>${text}</p>
      <div class="actions">
        <button class="primary" onclick="leaveGuest('login')">Войти</button>
        <button class="secondary" onclick="leaveGuest('reg')">Зарегистрироваться</button>
      </div>
    </div>`;
}

function leaveGuest(tab) {
  // выходим из гостя в auth screen
  token = null; me = null;
  localStorage.removeItem('gs_token'); clearSsoCookie();
  localStorage.removeItem('gs_me');
  stopNewCheck(); stopCountsUpdate();
  showAuthScreen();
  switchTab(tab || 'login');
}

function doLogout() {
  showConfirm({
    title: 'Выйти из аккаунта?',
    msg: 'Вы выйдете во всех вкладках GhostEcos — соцсеть, чат и магазин.',
    okText: 'Выйти',
    danger: true,
    onOk: () => { _doLogoutLocal(); showToast('Вы вышли'); }
  });
}
function _doLogoutLocal() {
  token = null; me = null;
  localStorage.removeItem('gs_token'); clearSsoCookie();
  localStorage.removeItem('gs_me');
  localStorage.removeItem('gs_seen');
  seenIds = new Set();
  feedPosts = []; feedOffset = 0; feedHasMore = true; renderStart = 0;
  stopNewCheck(); stopCountsUpdate();
  try { RT && RT.disconnect && RT.disconnect(); } catch(_) {}
  showAuthScreen();
  switchTab('login');
}

// SSO sync: токен удалён в другой вкладке → разлогиниваемся тут тоже
window.addEventListener('storage', (e) => {
  if (e.key === 'gs_token' && !e.newValue && token) {
    _doLogoutLocal();
  }
});
// При возвращении на вкладку — проверим cookie (могли разлогинить в другом проекте)
document.addEventListener('visibilitychange', () => {
  if (document.hidden || !token) return;
  const hasCookie = document.cookie.split(';').some(c => c.trim().startsWith('gs_token='));
  if (!hasCookie) _doLogoutLocal();
});

// ── INIT ───────────────────────────────────────────────────────────────────────

// ── Algo: алгоритмическая лента, целиком на клиенте ──────────────────────────
// Профиль интересов лежит в localStorage и обновляется на каждое взаимодействие.
// Сервер ничего об этом не знает.
const Algo = (() => {
  const KEY = 'gs_algo_profile_v1';
  const MAX_AUTHORS = 200, MAX_TAGS = 200, MAX_SEEN = 1000;
  const TAG_RE = /#([a-zа-я0-9_]{2,30})/giu;

  // Cap на веса — иначе один любимец может разрастись до бесконечности
  const W_CAP = 50;
  function clamp(v) { return Math.max(-W_CAP, Math.min(W_CAP, v)); }

  function load() {
    try {
      const p = JSON.parse(localStorage.getItem(KEY) || 'null');
      if (p && p.v >= 1) {
        // Защита: гарантируем существование всех полей
        p.commented = p.commented || [];
        p.authors = p.authors || {};
        p.tags = p.tags || {};
        // Миграция v1 → v2: clamp накопленные веса под новый cap
        if (p.v < 2) {
          for (const k in p.authors) p.authors[k] = clamp(p.authors[k]);
          for (const k in p.tags) p.tags[k] = clamp(p.tags[k]);
          p.v = 2;
        }
        return p;
      }
    } catch(_) {}
    return { v: 2, authors: {}, tags: {}, seen: [], hidden: [], blockedAuthors: [], dwell: {}, reacted: [], commented: [], shownCount: 0 };
  }
  function save(p) {
    // Обрезаем чтобы не разрастался localStorage
    p.seen = (p.seen || []).slice(-MAX_SEEN);
    const topK = (obj, n) => Object.fromEntries(Object.entries(obj).sort((a,b) => b[1]-a[1]).slice(0, n));
    p.authors = topK(p.authors || {}, MAX_AUTHORS);
    p.tags = topK(p.tags || {}, MAX_TAGS);
    try { localStorage.setItem(KEY, JSON.stringify(p)); } catch(_) {}
  }
  let profile = load();

  function bump(map, key, delta) { map[key] = clamp((map[key] || 0) + delta); }
  function extractTags(text) {
    if (!text) return [];
    const out = [];
    let m;
    TAG_RE.lastIndex = 0;
    while ((m = TAG_RE.exec(text)) !== null) out.push(m[1].toLowerCase());
    return out;
  }

  return {
    profile: () => profile,
    seenIds: () => new Set(profile.seen),
    snapshot: () => JSON.parse(JSON.stringify(profile)),

    // Сигналы — каждое действие двигает веса
    onReact(post, on) {
      // Idempotency: повторная реакция не накапливает вес, снятие не зарегистрированной — игнор
      const has = profile.reacted.includes(post.id);
      if (on && has) return;          // уже реагировал
      if (!on && !has) return;        // не было реакции
      const sign = on ? 1 : -1;
      bump(profile.authors, post.username, 3 * sign);
      extractTags(post.content).forEach(t => bump(profile.tags, t, 2 * sign));
      if (on) profile.reacted = [...profile.reacted, post.id].slice(-500);
      else profile.reacted = profile.reacted.filter(id => id !== post.id);
      save(profile);
    },
    onComment(post) {
      // Idempotency: один пост = один сигнал, сколько бы раз ни комментил
      if (profile.commented.includes(post.id)) return;
      bump(profile.authors, post.username, 5);
      extractTags(post.content).forEach(t => bump(profile.tags, t, 3));
      profile.commented = [...profile.commented, post.id].slice(-500);
      save(profile);
    },
    onFollow(username, on) {
      bump(profile.authors, username, on ? 10 : -8);
      save(profile);
    },
    onOpenProfile(username) {
      bump(profile.authors, username, 2);
      save(profile);
    },
    onTagClick(tag) {
      bump(profile.tags, tag.toLowerCase(), 5);
      save(profile);
    },
    onView(post, dwellMs) {
      // Был в зоне видимости. Сильный сигнал если >5с, слабый если 1-5с, отриц если <0.5с
      const sec = dwellMs / 1000;
      const w = sec > 5 ? 1.5 : sec > 1 ? 0.5 : -0.2;
      bump(profile.authors, post.username, w);
      if (sec > 3) extractTags(post.content).forEach(t => bump(profile.tags, t, 0.7));
      profile.dwell[post.id] = Math.max(profile.dwell[post.id] || 0, sec);
      if (!profile.seen.includes(post.id)) profile.seen.push(post.id);
      profile.shownCount = (profile.shownCount || 0) + 1;
      save(profile);
    },
    onHide(post) {
      bump(profile.authors, post.username, -8);
      extractTags(post.content).forEach(t => bump(profile.tags, t, -5));
      profile.hidden = [...new Set([...profile.hidden, post.id])].slice(-500);
      save(profile);
    },
    onBlockAuthor(username) {
      if (!profile.blockedAuthors.includes(username)) profile.blockedAuthors.push(username);
      save(profile);
    },

    // Ранжирование candidate-pool
    rank(posts) {
      const now = Date.now();
      const seenSet = new Set(profile.seen);
      const hiddenSet = new Set(profile.hidden);
      const blocked = new Set(profile.blockedAuthors);
      return posts
        .filter(p => !blocked.has(p.username) && !hiddenSet.has(p.id))
        .map(p => {
          let s = 0;
          // Вес автора
          s += (profile.authors[p.username] || 0) * 2.0;
          // Вес тегов поста
          const tags = extractTags(p.content);
          for (const t of tags) s += (profile.tags[t] || 0) * 1.5;
          // Engagement-сигнал самого поста
          const reacts = (p.reactions && p.reactions.total) || 0;
          const comms = p.comments_count || 0;
          s += (reacts * 0.4) + (comms * 0.6);
          // Тренд: реакций на час жизни
          const ageHrs = Math.max(0.5, (now - new Date(p.created_at + (p.created_at.endsWith('Z') ? '' : 'Z'))) / 3600000);
          s += (reacts + comms) / ageHrs;
          // Свежесть (мягкий decay)
          s -= ageHrs * 0.04;
          // Видел — penalty (растёт с количеством показов)
          if (seenSet.has(p.id)) s -= 15;
          // Уже реагировал/комментил — сильный penalty, чтобы не зацикливался
          if (profile.reacted.includes(p.id)) s -= 12;
          if (profile.commented.includes(p.id)) s -= 12;
          // Свой пост — крошечный плюс
          if (me && p.user_id === me.id) s += 0.5;
          // Dithering — рандомный шум против пузыря (5-15% от среднего веса)
          s += (Math.random() - 0.5) * 4;
          return { post: p, score: s };
        })
        .sort((a, b) => b.score - a.score)
        .map(x => x.post);
    },

    reset() {
      profile = { v: 1, authors: {}, tags: {}, seen: [], hidden: [], blockedAuthors: [], dwell: {}, reacted: [], shownCount: 0, lastSurvey: 0 };
      save(profile);
    },
    unblockAuthor(u) {
      profile.blockedAuthors = profile.blockedAuthors.filter(x => x !== u);
      save(profile);
    },
    removeAuthor(u) { delete profile.authors[u]; save(profile); },
    removeTag(t) { delete profile.tags[t]; save(profile); },
    markSurveyShown() { profile.lastSurvey = Date.now(); save(profile); },
  };
})();

// ── Survey: «Что вам интересно?» ─────────────────────────────────────────────
let _surveyPicks = new Set();

function shouldShowSurvey() {
  if (isGuest()) return false;
  const p = Algo.profile();
  const totalSignals = Object.keys(p.authors || {}).length + Object.keys(p.tags || {}).length;
  // Условия: профиль пустой, ИЛИ просмотрено 50+ постов с последнего опроса (минимум сутки между)
  const dayPassed = Date.now() - (p.lastSurvey || 0) > 24 * 3600 * 1000;
  if (totalSignals < 3 && p.shownCount > 5) return true;
  if (dayPassed && p.shownCount > 0 && p.shownCount % 50 === 0) return true;
  return false;
}

async function openSurvey() {
  document.getElementById('surveyModal').classList.add('open');
  _surveyPicks = new Set();
  const list = document.getElementById('surveyList');
  list.innerHTML = '<div class="loader"><div class="spinner"></div></div>';
  try {
    const data = await api('/post/feed?limit=12');
    // Берём 6 разнообразных — желательно от разных авторов
    const seen = new Set();
    const picks = [];
    for (const p of data) {
      if (picks.length >= 6) break;
      if (seen.has(p.username)) continue;
      seen.add(p.username);
      picks.push(p);
    }
    while (picks.length < 6 && picks.length < data.length) {
      const more = data.find(p => !picks.includes(p));
      if (more) picks.push(more); else break;
    }
    list.innerHTML = picks.map(p => `
      <div class="survey-card" data-pid="${p.id}" onclick="toggleSurveyPick(${p.id}, this)">
        <div class="survey-head">
          <span class="survey-author">@${esc(p.username)}</span>
          <span>·</span><span>${ago(p.created_at)}</span>
        </div>
        <div class="survey-text">${esc((p.content || '').slice(0, 200))}</div>
      </div>
    `).join('') || '<div class="empty"><p>Нет постов для опроса</p></div>';
    // Сохраняем сами объекты для submit
    window._surveyPosts = picks;
  } catch(e) {
    list.innerHTML = '<div class="empty"><i class="fa-solid fa-triangle-exclamation"></i><p>Ошибка загрузки</p></div>';
  }
}

function toggleSurveyPick(pid, card) {
  if (_surveyPicks.has(pid)) {
    _surveyPicks.delete(pid);
    card.classList.remove('picked');
  } else {
    if (_surveyPicks.size >= 5) { showToast('Максимум 5'); return; }
    _surveyPicks.add(pid);
    card.classList.add('picked');
  }
}

function openAlgoSettings() {
  renderAlgoSettings();
  document.getElementById('algoModal').classList.add('open');
}

function renderAlgoSettings() {
  const p = Algo.profile();
  const topAuthors = Object.entries(p.authors || {}).filter(([,w]) => w > 0).sort((a,b) => b[1]-a[1]).slice(0, 15);
  const topTags = Object.entries(p.tags || {}).filter(([,w]) => w > 0).sort((a,b) => b[1]-a[1]).slice(0, 15);
  const blocked = p.blockedAuthors || [];
  const stats = [
    ['Постов просмотрено', p.shownCount || 0],
    ['Реакций поставлено', (p.reacted || []).length],
    ['Скрытых постов', (p.hidden || []).length],
    ['Заблокированных авторов', blocked.length],
  ];
  document.getElementById('algoBody').innerHTML = `
    <div class="algo-section">
      <h4><i class="fa-solid fa-chart-simple" style="color:var(--primary);margin-right:6px;"></i>Статистика</h4>
      ${stats.map(([k,v]) => `<div class="algo-stat-row"><span>${k}</span><b>${v}</b></div>`).join('')}
    </div>
    <div class="algo-section">
      <h4><i class="fa-solid fa-users" style="color:var(--primary);margin-right:6px;"></i>Любимые авторы</h4>
      <div class="desc">Топ по вашим взаимодействиям. Клик ✕ — забыть.</div>
      <div class="algo-chips">
        ${topAuthors.length ? topAuthors.map(([u,w]) => `
          <span class="algo-chip">@${esc(u)} <span class="chip-w">${w.toFixed(0)}</span>
            <button class="chip-x" onclick="algoForget('author',${jsAttr(u)})" title="Забыть"><i class="fa-solid fa-xmark"></i></button>
          </span>`).join('') : '<span class="algo-empty">Пусто — взаимодействуй с постами</span>'}
      </div>
    </div>
    <div class="algo-section">
      <h4><i class="fa-solid fa-hashtag" style="color:var(--primary);margin-right:6px;"></i>Любимые теги</h4>
      <div class="desc">Теги из постов, с которыми вы взаимодействовали.</div>
      <div class="algo-chips">
        ${topTags.length ? topTags.map(([t,w]) => `
          <span class="algo-chip">#${esc(t)} <span class="chip-w">${w.toFixed(0)}</span>
            <button class="chip-x" onclick="algoForget('tag',${jsAttr(t)})" title="Забыть"><i class="fa-solid fa-xmark"></i></button>
          </span>`).join('') : '<span class="algo-empty">Пусто</span>'}
      </div>
    </div>
    <div class="algo-section">
      <h4><i class="fa-solid fa-user-slash" style="color:var(--primary);margin-right:6px;"></i>Скрытые авторы</h4>
      <div class="desc">Их посты не попадают в «Для вас».</div>
      <div class="algo-chips">
        ${blocked.length ? blocked.map(u => `
          <span class="algo-chip">@${esc(u)}
            <button class="chip-x" onclick="algoUnblock(${jsAttr(u)})" title="Вернуть">×</button>
          </span>`).join('') : '<span class="algo-empty">Никого</span>'}
      </div>
    </div>`;
}

function algoForget(kind, key) {
  if (kind === 'author') Algo.removeAuthor(key);
  else Algo.removeTag(key);
  renderAlgoSettings();
}

function algoUnblock(u) {
  Algo.unblockAuthor(u);
  renderAlgoSettings();
  showToast(`@${u} разблокирован`);
}

function algoReset() {
  showConfirm({
    title: 'Сбросить алгоритм?',
    msg: 'Все ваши предпочтения, история просмотров и блокировки будут стёрты. Сервер ничего не знает — это только на устройстве.',
    okText: 'Сбросить',
    danger: true,
    onOk: () => {
      Algo.reset();
      renderAlgoSettings();
      showToast('Алгоритм сброшен');
      if (currentSort === 'foryou') { resetFeed(); loadFeed(); }
    },
  });
}

function surveySubmit() {
  // Каждый выбранный пост — это сильный сигнал интереса
  const posts = window._surveyPosts || [];
  posts.forEach(p => {
    if (_surveyPicks.has(p.id)) {
      Algo.onReact(p, true);   // как лайк по силе
      Algo.onComment(p);       // + ещё +5 авторам, +3 тегам (двойной буст)
    }
  });
  Algo.markSurveyShown();
  closeModal('surveyModal');
  if (_surveyPicks.size > 0) {
    showToast(`Запомнено: ${_surveyPicks.size}. Лента обновится.`);
    // Перерисуем ленту если на «Для вас»
    if (currentSort === 'foryou') { resetFeed(); loadFeed(); }
  }
}

async function init() {
  if (!token) { showAuthScreen(); return; }
  // Гарантируем SSO-cookie на случай если юзер залогинен ДО введения SSO
  setSsoCookie(token);
  // Validate token
  try {
    const d = await api('/me');
    me = { ...me, id: d.id || d.user_id, username: d.username, display_name: d.display_name, is_guest: !!d.is_guest };
    localStorage.setItem('gs_me', JSON.stringify(me));
  } catch(e) {
    token = null; me = null;
    localStorage.removeItem('gs_token'); clearSsoCookie();
    localStorage.removeItem('gs_me');
    showAuthScreen();
    return;
  }
  showApp();
  document.body.classList.add('feed-mode');
  startPolling();
  handleHashRoute();
}

// ── Hash routing (#p=123, #tag=foo, #u=username, #screenXxx) + query (?p=, ?u=, ?msk=)
function handleHashRoute() {
  const h = location.hash || '';
  const q = new URLSearchParams(location.search);
  let handled = false;
  // Query-параметры (приходят из serv-redirect-ов /p/{id} → /social/?p=ID)
  const qp = q.get('p'), qu = q.get('u'), qmsk = q.get('msk');
  if (qp && !isNaN(parseInt(qp, 10))) {
    openSinglePost(parseInt(qp, 10));
    handled = true;
  } else if (qu) {
    openFullProfile(qu);
    handled = true;
  } else if (qmsk) {
    // Миниска — переключаем на /screenMinisky и подсвечиваем
    if (typeof openMiniska === 'function') openMiniska(parseInt(qmsk, 10));
    else switchScreen('screenMinisky');
    handled = true;
  } else if (h.startsWith('#p=')) {
    const id = parseInt(h.slice(3), 10);
    if (id) { openSinglePost(id); handled = true; }
  } else if (h.startsWith('#tag=')) {
    const t = decodeURIComponent(h.slice(5));
    if (t) { openTag(t); handled = true; }
  } else if (h.startsWith('#u=')) {
    const u = decodeURIComponent(h.slice(3));
    if (u) { openFullProfile(u); handled = true; }
  } else if (h.length > 1) {
    // Прямой переход к экрану: /social/#screenMinisky, /social/#screenFeed и т.п.
    const screenId = h.slice(1);
    if (screenId.startsWith('screen') && document.getElementById(screenId)) {
      switchScreen(screenId);
      handled = true;
    }
  }
  // Чистим хеш и query из адресной строки, чтобы остался /social
  if (handled) {
    history.replaceState(null, '', location.pathname);
  }
}

async function openSinglePost(postId) {
  try {
    const p = await api(`/post/${postId}`);
    // Переключиться на ленту
    document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
    document.getElementById('navFeed').classList.add('active');
    document.getElementById('screenFeed').classList.add('active');
    startNewCheck();
    // Если поста ещё нет в ленте — добавим карточку наверх (как «закреплённую» для просмотра)
    let card = document.querySelector(`.post-card[data-id="${postId}"]`);
    if (!card) {
      const list = document.getElementById('feedList');
      if (!feedPosts.find(x => x.id === p.id)) feedPosts.unshift(p);
      // Если лента ещё пустая — отрендерим как обычно
      if (list.querySelector('.skel-post') || list.querySelector('.empty') || !list.querySelector('.post-card')) {
        renderFeed();
      } else {
        list.insertAdjacentHTML('afterbegin', postHTML(p));
        attachEvents(); attachDoubleTap(); loadPreviews(); initAllAudios();
      }
      card = document.querySelector(`.post-card[data-id="${postId}"]`);
    }
    if (card) {
      // Небольшая задержка чтоб DOM устаканился после рендера
      setTimeout(() => {
        card.scrollIntoView({ behavior: 'smooth', block: 'center' });
        flashHighlight(card);
      }, 80);
    }
  } catch(e) {
    showToast('Пост не найден');
  }
}

function flashHighlight(el) {
  el.classList.add('post-highlight');
  setTimeout(() => el.classList.remove('post-highlight'), 2500);
}

// Время чтения — примерно 200 символов в минуту чтения для кириллицы.
// Не показываем если меньше 30 сек (= ~100 символов) — лишний шум.
function readTime(post) {
  if (!post || !post.content) return null;
  const chars = post.content.length;
  if (chars < 100) return null;
  const min = Math.max(1, Math.round(chars / 1000));
  return `${min} мин`;
}

// Двойной тап на пост = лайк + анимация сердца
function _onDoubleTap(card, pid) {
  const p = findPost(pid);
  if (!p || isGuest()) {
    if (isGuest()) guestBlock();
    return;
  }
  // Поставить heart (если уже стоит — оставить)
  const had = p.reactions && p.reactions.your_emoji === 'heart';
  if (!had) sendReaction(pid, 'heart');
  // Анимация в любом случае
  const h = document.createElement('div');
  h.className = 'dt-heart';
  h.innerHTML = emojiSvg('heart');
  card.appendChild(h);
  requestAnimationFrame(() => h.classList.add('go'));
  setTimeout(() => h.remove(), 900);
}

function attachDoubleTap() {
  document.querySelectorAll('.post-card[data-id]').forEach(card => {
    if (card._dtBound) return;
    card._dtBound = true;
    let lastTap = 0;
    const handler = e => {
      // Игнорируем тапы по интерактивным элементам
      if (e.target.closest('button, a, .react-trigger, .emoji-bar, .post-menu-btn, .post-follow-btn, .audio-widget, .post-header, .mg-item, .media-video-wrap')) {
        lastTap = 0;
        return;
      }
      const now = Date.now();
      if (now - lastTap < 350) {
        e.preventDefault();
        _onDoubleTap(card, +card.dataset.id);
        lastTap = 0;
      } else {
        lastTap = now;
      }
    };
    card.addEventListener('click', handler);
  });
}

window.addEventListener('hashchange', handleHashRoute);

// ── Pull-to-refresh ───────────────────────────────────────────────────────────
(function setupPTR() {
  const ind = () => document.getElementById('ptrIndicator');
  let startY = 0, pulling = false, refreshing = false;
  const THRESHOLD = 75;
  const MAX = 130;

  function onTouchStart(e) {
    if (refreshing) return;
    if (window.scrollY > 0) return;
    if (!document.getElementById('screenFeed').classList.contains('active')) return;
    startY = e.touches[0].clientY;
    pulling = true;
  }
  function onTouchMove(e) {
    if (!pulling || refreshing) return;
    const dy = e.touches[0].clientY - startY;
    if (dy < 0) { pulling = false; return; }
    const pull = Math.min(MAX, dy * 0.6);
    const el = ind();
    el.classList.add('show');
    el.style.transform = `translateX(-50%) translateY(${pull - 40}px) rotate(${(pull / THRESHOLD) * 180}deg)`;
  }
  function onTouchEnd(e) {
    if (!pulling) return;
    pulling = false;
    const dy = (e.changedTouches[0].clientY - startY) * 0.6;
    const el = ind();
    if (dy >= THRESHOLD && !refreshing) {
      refreshing = true;
      el.classList.add('spin');
      el.innerHTML = '<i class="fa-solid fa-spinner"></i>';
      el.style.transform = `translateX(-50%) translateY(${THRESHOLD - 40}px)`;
      // Обновляем
      (async () => {
        try {
          if (currentSort === 'new') { await prependNew(); }
          else { resetFeed(); await loadFeed(); }
        } catch(_) {}
        setTimeout(() => {
          refreshing = false;
          el.classList.remove('show', 'spin');
          el.style.transform = '';
          el.innerHTML = '<i class="fa-solid fa-arrow-down"></i>';
        }, 400);
      })();
    } else {
      el.classList.remove('show');
      el.style.transform = '';
    }
  }
  window.addEventListener('touchstart', onTouchStart, { passive: true });
  window.addEventListener('touchmove', onTouchMove, { passive: true });
  window.addEventListener('touchend', onTouchEnd);
})();

// ── Enter on auth inputs ───────────────────────────────────────────────────────
['loginUsername','loginPassword'].forEach(id => {
  document.getElementById(id).addEventListener('keydown', e => {
    if (e.key === 'Enter') doLogin();
  });
});
['regUsername','regName','regPassword','regPasswordConfirm'].forEach(id => {
  document.getElementById(id).addEventListener('keydown', e => {
    if (e.key === 'Enter') doRegister();
  });
});

// ── NAV ────────────────────────────────────────────────────────────────────────

function switchScreen(screenId) {
  // Гость — нельзя писать пост и нет своего профиля
  if (isGuest() && (screenId === 'screenCreate' || screenId === 'screenProfile')) {
    showGuestStub(screenId);
  }
  document.querySelectorAll('.nav-btn').forEach(b => b.classList.toggle('active', b.dataset.screen === screenId));
  document.querySelectorAll('.dt-nav-btn').forEach(b => b.classList.toggle('active', b.dataset.screen === screenId));
  document.querySelectorAll('.screen').forEach(s => s.classList.toggle('active', s.id === screenId));
  document.body.classList.toggle('feed-mode', screenId === 'screenFeed');
  document.body.classList.toggle('miniska-mode', screenId === 'screenMinisky');
  if (screenId === 'screenProfile' && !isGuest()) loadMyProfile();
  if (screenId === 'screenSearch') setTimeout(() => searchInput.focus(), 100);
  if (screenId === 'screenNotif') loadNotifications();
  if (screenId === 'screenWallet') loadWallet();
  if (screenId === 'screenMinisky') loadMinisky(); else stopMinisky();
  if (screenId === 'screenModeration') loadModerationScreen();
  if (screenId === 'screenFeed') startNewCheck(); else stopNewCheck();
  window.scrollTo({top: 0});
}

// ── КОШЕЛЁК ─────────────────────────────────────────────────────────────
let _walDailyTimer = null;
async function loadWallet(){
  if (isGuest()) return;
  try {
    const [w, tx] = await Promise.all([ api('/wallet'), api('/wallet/tx') ]);
    document.getElementById('walGost').textContent = (w.balance.gost || 0).toLocaleString('ru-RU');
    document.getElementById('walSoul').textContent = (w.balance.soul || 0).toLocaleString('ru-RU');
    document.getElementById('walPrem').textContent = (w.balance.prem || 0).toLocaleString('ru-RU');
    document.getElementById('walDailyAmt').textContent = w.daily_reward;
    updateGostPill(w.balance.gost || 0);
    setupDailyClaim(w.next_daily_in || 0);
    renderTxList(tx.transactions || []);
  } catch(e) { console.error('[wallet] load failed', e); }
}

function setupDailyClaim(secondsLeft){
  const btn = document.getElementById('walClaimBtn');
  const hint = document.getElementById('walClaimHint');
  const cd = document.getElementById('walClaimCountdown');
  clearInterval(_walDailyTimer);
  if (secondsLeft <= 0) {
    btn.disabled = false;
    btn.style.display = '';
    hint.style.display = 'none';
    return;
  }
  btn.disabled = true;
  hint.style.display = '';
  const tick = () => {
    if (secondsLeft <= 0) { clearInterval(_walDailyTimer); setupDailyClaim(0); return; }
    const h = Math.floor(secondsLeft / 3600);
    const m = Math.floor((secondsLeft % 3600) / 60);
    const s = secondsLeft % 60;
    cd.textContent = `${String(h).padStart(2,'0')}:${String(m).padStart(2,'0')}:${String(s).padStart(2,'0')}`;
    secondsLeft--;
  };
  tick();
  _walDailyTimer = setInterval(tick, 1000);
}

async function claimDaily(){
  const btn = document.getElementById('walClaimBtn');
  btn.disabled = true;
  try {
    const r = await api('/wallet/claim_daily', 'POST');
    if (r.credited > 0) showToast(`+${r.credited} Gost получено!`);
    await loadWallet();
  } catch(e) {
    showToast(e.message || 'Не удалось получить бонус');
    btn.disabled = false;
  }
}

function updateGostPill(val){
  const el = document.getElementById('gostPillVal');
  const pill = document.getElementById('gostPill');
  if (!el || !pill) { console.warn('[gostPill] elem not found, val=', val); return; }
  const prev = +(el.textContent.replace(/\s/g, '')) || 0;
  const next = Number.isFinite(+val) ? +val : prev;
  el.textContent = next.toLocaleString('ru-RU');
  console.log('[gostPill] update', prev, '→', next);
  if (next > prev) {
    pill.classList.remove('bump');
    void pill.offsetWidth; // restart animation
    pill.classList.add('bump');
  }
}

// Тихий fetch баланса как страховка к WS-событию wallet.credit.
// Debounce 400мс: при rapid clicks (например 5 лайков подряд) запрос один.
let _walRefreshT = null;
function refreshWallet(){
  if (isGuest()) return;
  clearTimeout(_walRefreshT);
  _walRefreshT = setTimeout(async () => {
    try {
      const w = await api('/wallet');
      updateGostPill(w.balance.gost || 0);
      // Если открыт экран кошелька — синкаем и его
      if (document.getElementById('screenWallet').classList.contains('active')) {
        document.getElementById('walGost').textContent = (w.balance.gost || 0).toLocaleString('ru-RU');
        const tx = await api('/wallet/tx');
        renderTxList(tx.transactions || []);
      }
    } catch(_) {}
  }, 400);
}

// Когда вкладка возвращается в фокус — синкаем баланс.
// Это ловит случай: PWA в фоне → WS отрубается → нам что-то начислили → возвращаемся → видим актуал.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') refreshWallet();
});
window.addEventListener('focus', () => refreshWallet());

const TX_SOURCE_META = {
  'register': {icon:'fa-gift',         label:'Welcome бонус'},
  'daily':    {icon:'fa-gift',         label:'Ежедневный бонус'},
  'post':     {icon:'fa-pen',          label:'За пост'},
  'react':    {icon:'fa-heart',        label:'Лайк на твой пост'},
  'comment':  {icon:'fa-comment',      label:'Коммент на твой пост'},
  'follow':   {icon:'fa-user-plus',    label:'Новый подписчик'},
  'spend':    {icon:'fa-cart-shopping',label:'Покупка'},
  'admin':    {icon:'fa-shield',       label:'От администрации'},
};
function renderTxList(list){
  const root = document.getElementById('walTxList');
  if (!list.length) { root.innerHTML = '<div class="tx-empty">Пока пусто. Активничай — Gost начнут капать.</div>'; return; }
  root.innerHTML = list.map(t => {
    const meta = TX_SOURCE_META[t.source] || {icon:'fa-coins', label:t.source};
    const sign = t.delta > 0 ? '+' : '';
    const cls = t.delta < 0 ? 'tx-amount neg' : 'tx-amount';
    const actorPart = t.actor ? ` · @${esc(t.actor.username)}` : '';
    const when = ago(t.created_at);
    return `<div class="tx-item">
      <div class="tx-icon"><i class="fa-solid ${meta.icon}"></i></div>
      <div class="tx-body">
        <div class="tx-title">${esc(meta.label)}</div>
        <div class="tx-meta">${when}${actorPart}</div>
      </div>
      <div class="${cls}">${sign}${t.delta} ${t.currency}</div>
    </div>`;
  }).join('');
}

document.querySelectorAll('.nav-btn, .dt-nav-btn, .dt-create-btn').forEach(btn => {
  btn.addEventListener('click', () => switchScreen(btn.dataset.screen));
});

function goProfile() {
  switchScreen('screenProfile');
}

// ── FILTERS ────────────────────────────────────────────────────────────────────

document.querySelectorAll('.filter-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    currentSort = btn.dataset.sort;
    // Новый seed при каждом включении «Рандом» и при повторном клике по кнопке
    if (currentSort === 'random') randomSeed = Math.floor(Math.random() * 999983) + 1;
    // Гость не может в «Для вас» — fallback на «Новые»
    if (currentSort === 'foryou' && isGuest()) {
      currentSort = 'new';
      document.querySelectorAll('.filter-btn').forEach(b => b.classList.toggle('active', b.dataset.sort === 'new'));
    }
    resetFeed(); loadFeed();
    // Пилюля «Новые» работает только для фильтра «Новые»
    if (currentSort === 'new') startNewCheck();
    else { stopNewCheck(); hidePill(); }
    // На «Для вас» — предложим опрос если профиль пустой
    if (currentSort === 'foryou' && shouldShowSurvey()) {
      setTimeout(openSurvey, 600);
    }
  });
});

// ── FEED ───────────────────────────────────────────────────────────────────────

function resetFeed() {
  feedPosts = []; feedOffset = 0; feedHasMore = true; renderStart = 0;
  document.getElementById('feedList').innerHTML = skeletonPosts(3);
}

function skeletonPosts(n) {
  let html = '';
  for (let i = 0; i < n; i++) {
    html += `<div class="skel-post">
      <div class="skel-row"><div class="skel skel-av"></div><div class="skel skel-name"></div></div>
      <div class="skel skel-line medium"></div>
      <div class="skel skel-line short"></div>
    </div>`;
  }
  return html;
}

async function loadFeed(append = false) {
  if (feedLoading || (!feedHasMore && append)) return;
  feedLoading = true;
  if (append) document.getElementById('feedLoader').style.display = 'block';
  try {
    let data;
    if (currentSort === 'foryou') {
      // Алгоритмическая лента: получаем candidate-pool и ранжируем локально
      const seen = Algo.seenIds();
      const exclude = append ? [...seen].slice(-200).join(',') : '';
      const raw = await api(`/post/feed?limit=50&offset=${feedOffset}${exclude ? '&exclude=' + encodeURIComponent(exclude) : ''}`);
      // ранжируем
      const ranked = Algo.rank(raw);
      data = ranked;
    } else {
      let url = `/post?sort=${currentSort}&offset=${feedOffset}`;
      if (currentTag) url += `&tag=${encodeURIComponent(currentTag)}`;
      if (currentSort === 'random') url += `&seed=${randomSeed}`;
      data = await api(url);
    }
    feedOffset += data.length;
    if (data.length < PAGE) feedHasMore = false;
    feedPosts = append ? [...feedPosts, ...data] : data;
    // При первой/новой загрузке всё считается прочитанным
    if (!append) lastSeenMaxId = maxFeedId();
    renderFeed();
  } catch(e) {
    if (!append) document.getElementById('feedList').innerHTML = '<div class="empty"><i class="fa-solid fa-triangle-exclamation"></i><p>Ошибка загрузки</p></div>';
  }
  feedLoading = false;
  document.getElementById('feedLoader').style.display = 'none';
}

function maxFeedId() {
  return feedPosts.reduce((m, p) => p.id > m ? p.id : m, 0);
}

function renderFeed() {
  const list = document.getElementById('feedList');
  const visible = feedPosts.slice(renderStart);
  if (!visible.length) { list.innerHTML = '<div class="empty"><i class="fa-regular fa-newspaper"></i><p>Постов пока нет — будь первым!</p></div>'; return; }
  // Вставляем разделитель "Непрочитанное" между постами с id > lastSeenMaxId и остальными
  let html = '';
  let sepInserted = false;
  visible.forEach(p => {
    if (!sepInserted && lastSeenMaxId > 0 && p.id <= lastSeenMaxId && visible.some(x => x.id > lastSeenMaxId)) {
      html += unreadSepHTML();
      sepInserted = true;
    }
    html += postHTML(p);
  });
  list.innerHTML = html;
  attachEvents(); attachDoubleTap(); loadPreviews(); initAllAudios();
  attachDoubleTap();
  observeDots();
  observeUnreadSep();
  observeDwell();
}

function unreadSepHTML() {
  return `<div class="unread-sep" id="unreadSep"><i class="fa-solid fa-arrow-up"></i><span>Непрочитанное</span></div>`;
}

function observeUnreadSep() {
  const sep = document.getElementById('unreadSep');
  if (!sep) return;
  let wasSeen = false;
  const obs = new IntersectionObserver(entries => {
    entries.forEach(e => {
      if (e.isIntersecting) { wasSeen = true; return; }
      // удаляем ТОЛЬКО когда был виден хоть раз и потом ушёл вверх
      if (wasSeen && e.boundingClientRect.top < 0) {
        sep.style.transition = 'opacity 0.3s';
        sep.style.opacity = '0';
        setTimeout(() => sep.remove(), 300);
        lastSeenMaxId = maxFeedId();
        obs.disconnect();
      }
    });
  }, { threshold: 0, rootMargin: `-${parseInt(getComputedStyle(document.documentElement).getPropertyValue('--header-h')) || 100}px 0px 0px 0px` });
  obs.observe(sep);
}

function scrollToSep(sep) {
  // Хотим, чтобы разделитель оказался по середине окна между шапкой и низом
  const headerH = parseInt(getComputedStyle(document.documentElement).getPropertyValue('--header-h')) || 100;
  const visibleH = window.innerHeight - headerH;
  const sepH = sep.offsetHeight;
  const targetTop = headerH + (visibleH - sepH) / 2;  // желаемая координата top разделителя в viewport
  const y = window.scrollY + sep.getBoundingClientRect().top - targetTop;
  window.scrollTo({top: Math.max(0, y), behavior: 'smooth'});
}

async function prependNew() {
  if (currentSort !== 'new') return 0;
  try {
    const data = await api(`/post?sort=new&offset=0`);
    const lastId = maxFeedId();
    const fresh = data.filter(p => p.id > lastId);
    if (!fresh.length) return 0;
    feedPosts = [...fresh, ...feedPosts];
    feedOffset += fresh.length;
    renderStart = 0;  // показать с начала
    renderFeed();
    return fresh.length;
  } catch(e) { return 0; }
}

// ── Emoji map ──────────────────────────────────────────────────────────────────

// Кастомные SVG эмодзи (фирменный стиль GhostSocial, viewBox 32×32, размер через CSS .emo).
const EMOJI = {
  heart: { ch: `<svg class="emo" viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="he" x1="0.3" y1="0" x2="0.7" y2="1"><stop offset="0" stop-color="#fb7185"/><stop offset="1" stop-color="#e11d48"/></linearGradient></defs><path d="M16 28.5 C 5 21 2 15.5 2 10.5 C 2 6.5 5.2 3.5 9 3.5 C 12 3.5 14.4 5.2 16 7.8 C 17.6 5.2 20 3.5 23 3.5 C 26.8 3.5 30 6.5 30 10.5 C 30 15.5 27 21 16 28.5 Z" fill="url(#he)"/><path d="M9 7 C 7 8 6 10 6 11.5" stroke="#fff" stroke-width="2" stroke-linecap="round" fill="none" opacity="0.55"/></svg>`, label: 'Сердце' },
  fire:  { ch: `<svg class="emo" viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="fo" x1="0.5" y1="1" x2="0.5" y2="0"><stop offset="0" stop-color="#dc2626"/><stop offset="0.55" stop-color="#f97316"/><stop offset="1" stop-color="#fde047"/></linearGradient><linearGradient id="fi" x1="0.5" y1="1" x2="0.5" y2="0"><stop offset="0" stop-color="#fde047"/><stop offset="1" stop-color="#fef9c3"/></linearGradient></defs><path d="M16 2 C 14 6 11 9 9 13 C 7 17 6 21 6 23 C 6 28 10 30 16 30 C 22 30 26 28 26 23 C 26 19 23.5 17 22 14 C 21 16 19.5 17 18 16.5 C 18 12 17.5 7 16 2 Z" fill="url(#fo)"/><path d="M16 14 C 14.5 17 13 19 13 22 C 13 25.5 14.5 27.5 16 27.5 C 17.5 27.5 19 25.5 19 22 C 19 19 17.5 17 16 14 Z" fill="url(#fi)"/></svg>`, label: 'Огонь' },
  laugh: { ch: `<svg class="emo" viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><defs><radialGradient id="la" cx="0.4" cy="0.32" r="0.75"><stop offset="0" stop-color="#fef08a"/><stop offset="1" stop-color="#eab308"/></radialGradient></defs><circle cx="16" cy="16" r="13.5" fill="url(#la)" stroke="#a16207" stroke-width="0.6"/><path d="M8.5 13 Q 10.5 10.5 12.5 13" stroke="#1e293b" stroke-width="2" fill="none" stroke-linecap="round"/><path d="M19.5 13 Q 21.5 10.5 23.5 13" stroke="#1e293b" stroke-width="2" fill="none" stroke-linecap="round"/><path d="M10 19 Q 16 27 22 19 Z" fill="#1e293b"/><path d="M12 21 Q 16 25 20 21 Q 16 23 12 21 Z" fill="#f43f5e"/></svg>`, label: 'Смех' },
  sad:   { ch: `<svg class="emo" viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><defs><radialGradient id="sa" cx="0.4" cy="0.32" r="0.75"><stop offset="0" stop-color="#fef08a"/><stop offset="1" stop-color="#eab308"/></radialGradient></defs><circle cx="16" cy="16" r="13.5" fill="url(#sa)" stroke="#a16207" stroke-width="0.6"/><circle cx="11" cy="14" r="1.8" fill="#1e293b"/><circle cx="21" cy="14" r="1.8" fill="#1e293b"/><path d="M10 23 Q 16 18 22 23" stroke="#1e293b" stroke-width="2" fill="none" stroke-linecap="round"/><path d="M11 16 C 10 18 9 21 10 23 C 11.5 22 12 19 11 16 Z" fill="#38bdf8"/></svg>`, label: 'Грусть' },
  clap:  { ch: `<svg class="emo" viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="cl" x1="0.5" y1="0" x2="0.5" y2="1"><stop offset="0" stop-color="#fcd34d"/><stop offset="1" stop-color="#d97706"/></linearGradient></defs><g transform="translate(2 2) rotate(-12 14 14)"><path d="M6 6 Q 4 16 6 22 L 14 24 Q 16 18 14 8 Z" fill="url(#cl)" stroke="#92400e" stroke-width="0.5"/><path d="M8 6 L 8 16 M 10 5 L 10 16 M 12 6 L 12 16" stroke="#92400e" stroke-width="0.8" opacity="0.5"/></g><g transform="translate(2 2) rotate(12 14 14)"><path d="M22 6 Q 24 16 22 22 L 14 24 Q 12 18 14 8 Z" fill="url(#cl)" stroke="#92400e" stroke-width="0.5"/><path d="M20 6 L 20 16 M 18 5 L 18 16 M 16 6 L 16 16" stroke="#92400e" stroke-width="0.8" opacity="0.5"/></g><path d="M3 6 L 5 7 M 3 11 L 5 11 M 4 16 L 6 15" stroke="#a855f7" stroke-width="1.4" stroke-linecap="round"/><path d="M29 6 L 27 7 M 29 11 L 27 11 M 28 16 L 26 15" stroke="#a855f7" stroke-width="1.4" stroke-linecap="round"/></svg>`, label: 'Хлопок' },
  eyes:  { ch: `<svg class="emo" viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><ellipse cx="10" cy="16" rx="7.5" ry="8.5" fill="#fff" stroke="#1e293b" stroke-width="1.4"/><ellipse cx="22" cy="16" rx="7.5" ry="8.5" fill="#fff" stroke="#1e293b" stroke-width="1.4"/><circle cx="12" cy="17" r="3.4" fill="#1e293b"/><circle cx="24" cy="17" r="3.4" fill="#1e293b"/><circle cx="13.2" cy="15.8" r="1.1" fill="#fff"/><circle cx="25.2" cy="15.8" r="1.1" fill="#fff"/></svg>`, label: 'Глаза' },
};
const EMOJI_ORDER = ['heart','fire','laugh','sad','clap','eyes'];

// SVG-градиенты используют id (he, fo, la, sa, cl) — если ID повторяются на странице,
// браузер начинает путать defs соседних SVG, и второй+ рисуются пустыми.
// Поэтому при каждом рендере добавляем уникальный suffix.
let _emojiUid = 0;
function emojiSvg(key) {
  const tpl = EMOJI[key] && EMOJI[key].ch;
  if (!tpl) return '';
  const suf = '-' + (++_emojiUid).toString(36);
  // заменяем id="..." и url(#...) в одном SVG на уникальные
  return tpl.replace(/id="([a-zA-Z][\w-]*)"/g, (m, id) => `id="${id}${suf}"`)
            .replace(/url\(#([a-zA-Z][\w-]*)\)/g, (m, id) => `url(#${id}${suf})`);
}

// ── Media HTML ─────────────────────────────────────────────────────────────────

function mediaHTML(media) {
  if (!media || !media.length) return '';
  const imgs = media.filter(m => m.type === 'image');
  const vids = media.filter(m => m.type === 'video');
  const auds = media.filter(m => m.type === 'audio');
  let html = '<div class="post-media">';
  const visual = [...imgs, ...vids];
  if (visual.length) {
    const n = visual.length;
    const gc = n === 1 ? 'g1' : n === 2 ? 'g2' : n === 3 ? 'g3' : n === 4 ? 'g4' : 'g5';
    html += `<div class="media-grid ${gc}">`;
    visual.forEach(m => {
      const tall = n === 1 ? 'tall' : '';
      const urlAttr = esc(m.url);
      const urlJs = jsAttr(m.url);
      if (m.type === 'image') {
        html += `<div class="mg-item ${tall} media-el" data-media-url="${urlAttr}" onclick="openViewer(${urlJs},'image')">
          <img src="${urlAttr}" loading="lazy" alt="">
        </div>`;
      } else {
        html += `<div class="mg-item ${tall} media-el" data-media-url="${urlAttr}" onclick="openViewer(${urlJs},'video')">
          <video src="${urlAttr}" preload="metadata" muted playsinline></video>
          <div class="video-play-overlay"><div class="video-play-btn"><i class="fa-solid fa-play"></i></div></div>
        </div>`;
      }
    });
    html += '</div>';
  }
  auds.forEach(m => {
    const id = audId(m.url);
    const bars = genWave(m.url, 50).map(h => `<div class="audio-bar" style="height:${Math.round(h*100)}%"></div>`).join('');
    html += `<div class="audio-widget media-el" data-media-url="${esc(m.url)}" data-audio-id="${id}" data-audio-url="${esc(m.url)}">
      <div class="audio-top">
        <button class="audio-play-btn" id="${id}_btn" onclick="event.stopPropagation();toggleAudio(${jsAttr(id)},${jsAttr(m.url)})"><i class="fa-solid fa-play"></i></button>
        <div class="audio-waveform" id="${id}_wf" onclick="event.stopPropagation();seekAudio('${id}',event)">${bars}</div>
      </div>
      <div class="audio-time" id="${id}_time">0:00</div>
    </div>`;
  });
  html += '</div>';
  return html;
}

// ── Linkify (hashtags + mentions) ──────────────────────────────────────────────

// Применяет esc() и подменяет #tag и @user на кликабельные ссылки.
// Если передан hq — дополнительно подсвечивает совпадения (поиск).
// ── Link preview ──────────────────────────────────────────────────────────────
const LINK_RE = /\bhttps?:\/\/[^\s<>"']+/gi;
const _previewCache = new Map(); // url -> data | null (если null — не нашлось)
const _previewSeenInPost = new Set(); // postId, чтобы не дёргать дважды

function firstUrl(text) {
  if (!text) return null;
  const m = text.match(LINK_RE);
  return m ? m[0].replace(/[.,;!?)]+$/, '') : null;
}

function linkPreviewPlaceholder(p) {
  const u = firstUrl(p.content);
  if (!u) return '';
  // Используем data-pid+data-url, потом обработчик подгрузит превью
  return `<div class="link-preview-loading" data-prev-pid="${p.id}" data-prev-url="${esc(u)}">
    <div class="spinner spinner-sm"></div><span>${esc(u.slice(0, 60))}</span>
  </div>`;
}

async function loadPreviews() {
  document.querySelectorAll('[data-prev-pid]').forEach(async el => {
    if (el._loadStarted) return;
    el._loadStarted = true;
    const url = el.dataset.prevUrl;
    if (!url) return;
    try {
      let data = _previewCache.get(url);
      if (data === undefined) {
        data = await api(`/linkpreview?url=${encodeURIComponent(url)}`);
        _previewCache.set(url, data);
      }
      if (!data || !data.title) { el.remove(); return; }
      el.outerHTML = `<a class="link-preview" href="${esc(data.url)}" target="_blank" rel="noopener noreferrer">
        ${data.image ? `<div class="link-preview-img" style="background-image:url('${esc(data.image)}')"></div>` : ''}
        <div class="link-preview-body">
          ${data.site ? `<div class="link-preview-site">${esc(data.site)}</div>` : ''}
          <div class="link-preview-title">${esc(data.title)}</div>
          ${data.description ? `<div class="link-preview-desc">${esc(data.description)}</div>` : ''}
        </div>
      </a>`;
    } catch(_) {
      _previewCache.set(url, null);
      el.remove();
    }
  });
}

// ── Poll render ────────────────────────────────────────────────────────────────
function pollHTML(p) {
  if (!p.poll) return '';
  const q = p.poll;
  const voted = q.my_vote !== null && q.my_vote !== undefined;
  const isQuiz = q.is_quiz;
  const badge = isQuiz ? '<span class="badge"><i class="fa-solid fa-graduation-cap"></i> Викторина</span>' : '<span class="badge"><i class="fa-solid fa-chart-simple"></i> Опрос</span>';
  const opts = (q.options || []).map((opt, i) => {
    const cnt = (q.counts && q.counts[i]) || 0;
    const pct = q.total > 0 ? Math.round(cnt / q.total * 100) : 0;
    let cls = '';
    let icon = '';
    if (voted) {
      cls += ' voted';
      if (i === q.my_vote) cls += ' mine';
      if (isQuiz && q.correct_idx !== null && q.correct_idx !== undefined) {
        if (i === q.correct_idx) { cls += ' correct'; icon = '<i class="fa-solid fa-check poll-opt-icon ok"></i>'; }
        else if (i === q.my_vote) { cls += ' wrong'; icon = '<i class="fa-solid fa-xmark poll-opt-icon bad"></i>'; }
      }
    }
    return `<button class="poll-opt${cls}" ${voted ? '' : `onclick="votePoll(${p.id}, ${i})"`}>
      <div class="poll-opt-fill" style="width:${voted ? pct : 0}%"></div>
      <span class="poll-opt-label">${esc(opt)}</span>
      ${voted ? `${icon}<span class="poll-opt-pct">${pct}%</span>` : ''}
    </button>`;
  }).join('');
  return `<div class="poll">
    <div class="poll-q">${badge} ${esc(q.question)}</div>
    ${opts}
    ${voted ? `<div class="poll-total">${q.total} ${pluralVoices(q.total)}</div>` : ''}
  </div>`;
}

function pluralVoices(n) {
  const r = n % 10, h = n % 100;
  if (h >= 11 && h <= 14) return 'голосов';
  if (r === 1) return 'голос';
  if (r >= 2 && r <= 4) return 'голоса';
  return 'голосов';
}

async function votePoll(postId, idx) {
  if (isGuest()) { guestBlock(); return; }
  try {
    const state = await api(`/post/${postId}/vote`, 'POST', { option_idx: idx });
    const p = findPost(postId);
    if (p) {
      p.poll = state;
      document.querySelectorAll(`.post-card[data-id="${postId}"] .poll`).forEach(el => {
        el.outerHTML = pollHTML(p);
      });
    }
  } catch(e) { showToast('Ошибка голосования'); }
}

function linkifyContent(raw, hq) {
  let html = highlightText(raw, hq);
  // hashtag: лат/кирилл/цифры/_, 1..30. Сначала теги, потом @ — порядок не важен.
  html = html.replace(/(^|[^&\w])#([0-9A-Za-zА-Яа-яЁё_]{1,30})/gu,
    (m, pre, tag) => `${pre}<a class="hashtag" href="#tag=${encodeURIComponent(tag.toLowerCase())}" onclick="event.preventDefault();openTag(${jsAttr(tag.toLowerCase())})">#${tag}</a>`);
  html = html.replace(/(^|[^&\w])@([a-z0-9._]{3,64})/g,
    (m, pre, u) => `${pre}<a class="mention" href="#u=${encodeURIComponent(u)}" onclick="event.preventDefault();openFullProfile(${jsAttr(u)})">@${u}</a>`);
  return html;
}

// ── Post HTML ──────────────────────────────────────────────────────────────────

function reactionsHTML(p) {
  const counts = (p.reactions && p.reactions.counts) || {};
  const your = p.reactions && p.reactions.your_emoji;
  // отсортируем по порядку EMOJI_ORDER
  const items = EMOJI_ORDER.filter(k => counts[k]).map(k => {
    const cls = k === your ? ' mine' : '';
    return `<span class="react-pill${cls}" data-emoji="${k}" data-action="react-pill">${emojiSvg(k)}${counts[k]}</span>`;
  }).join('');
  return items;
}

function postHTML(p, hq) {
  const isNew = !seenIds.has(p.id);
  const isOwn = me && p.user_id === me.id;
  const your = p.reactions && p.reactions.your_emoji;
  const isNsfw = !!p.is_nsfw;
  const nsfwByAdmin = !!p.nsfw_set_by_admin;
  const nsfwBadge = isNsfw
    ? `<span class="nsfw-badge-header${nsfwByAdmin ? ' nsfw-by-admin' : ''}" title="${nsfwByAdmin ? 'Помечено модерацией: автор не указал NSFW' : 'Автор пометил 18+'}">18+</span>`
    : '';
  const nsfwOverlay = isNsfw
    ? `<div class="nsfw-overlay" data-action="nsfw-reveal" data-post="${p.id}">
         <span class="nsfw-overlay-badge"><i class="fa-solid fa-eye-slash"></i> 18+ NSFW</span>
         <span class="nsfw-overlay-text">${nsfwByAdmin ? 'Помечено модерацией' : 'Содержит контент для взрослых'}</span>
         <span class="nsfw-overlay-cta">Показать</span>
       </div>`
    : '';
  const isRepost = !!p.is_repost;
  const repostLabel = isRepost ? `<div class="repost-mark"><i class="fa-solid fa-retweet"></i> репост</div>` : '';
  return `<div class="post-card${isNsfw ? ' nsfw' : ''}${isRepost ? ' repost' : ''}" data-id="${p.id}" style="${isNsfw ? 'position:relative;' : ''}">
    ${repostLabel}
    ${isNew ? `<div class="new-marker" data-dot="${p.id}">NEW</div>` : ''}
    <button class="post-menu-btn" data-action="menu" data-post="${p.id}" title="Меню"><i class="fa-solid fa-ellipsis"></i></button>
    ${p.from_channel ? `<div style="display:flex;align-items:center;gap:6px;padding:6px 10px;background:rgba(168,85,247,0.10);border:1px solid rgba(168,85,247,0.25);border-radius:8px;margin-bottom:8px;font-size:11px;color:var(--primary);font-weight:600;">
      <i class="fa-solid fa-bullhorn" style="font-size:10px;"></i>
      <span>Канал · <b>${esc(p.from_channel.name)}</b>${p.from_channel.username ? ' <span style="color:var(--sub);font-weight:500;">@'+esc(p.from_channel.username)+'</span>' : ''}</span>
    </div>` : ''}
    <div class="post-header" data-username="${esc(p.username)}">
      <div class="post-av">${ini(p.display_name)}</div>
      <div class="post-info">
        <div class="post-name">${esc(p.display_name)}${nsfwBadge}</div>
        <div class="post-user">@${esc(p.username)}</div>
      </div>
      ${isOwn
        ? `<span class="post-mine-label">это вы</span>`
        : (!isGuest() && !p.am_following
          ? `<button class="post-follow-btn" data-action="post-follow" data-username="${esc(p.username)}" title="Подписаться"><i class="fa-solid fa-plus"></i> Подписаться</button>`
          : '')}
      <div class="post-time" style="margin-right:36px">${ago(p.created_at)}${p.edited_at ? `<span class="post-edited" title="Отредактировано ${ago(p.edited_at)} назад">(ред.)</span>` : ''}${readTime(p) ? `<span class="post-read-time"><i class="fa-regular fa-clock"></i>${readTime(p)}</span>` : ''}</div>
    </div>
    ${nsfwOverlay}
    <div class="nsfw-blurable">
    <div class="post-content">${linkifyContent(p.content, hq)}</div>
    ${linkPreviewPlaceholder(p)}
    ${pollHTML(p)}
    ${mediaHTML(p.media)}
    </div>
    <div class="post-stats">
      <span title="Просмотров"><i class="fa-regular fa-eye"></i> ${formatCount(p.views_count || 0)}</span>
      ${(p.reposts_count || 0) > 0 ? `<span title="Репостов"><i class="fa-solid fa-retweet"></i> ${formatCount(p.reposts_count)}</span>` : ''}
    </div>
    <div class="post-footer">
      <div class="react-trigger" data-post="${p.id}">
        <button class="act-btn${your ? ' liked' : ''}" data-post="${p.id}" data-action="react-toggle">
          <i class="fa-${your ? 'solid' : 'regular'} fa-heart"></i>
        </button>
      </div>
      <div class="reactions-row" data-post="${p.id}" data-action="reactions-row">${reactionsHTML(p)}</div>
      <span class="repost-pill" data-post="${p.id}" data-action="repost-pill" style="display:none;"></span>
      <button class="act-btn" data-post="${p.id}" data-action="comment" style="margin-left:auto">
        <i class="fa-regular fa-comment"></i>
        <span class="cc">${p.comments_count}</span>
      </button>
      <button class="act-btn" data-post="${p.id}" data-action="share">
        <i class="fa-solid fa-share"></i>
      </button>
    </div>
  </div>`;
}

// ── Events ─────────────────────────────────────────────────────────────────────

function attachEvents() {
  // Reaction toggle (click = heart toggle, long-press = palette)
  document.querySelectorAll('[data-action="react-toggle"]').forEach(btn => {
    if (btn._b) return; btn._b = 1;
    let pressTimer = null, longPressed = false;
    const start = () => {
      longPressed = false;
      pressTimer = setTimeout(() => { longPressed = true; openEmojiPalette(btn); }, 400);
    };
    const cancel = () => { if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; } };
    btn.addEventListener('mousedown', start);
    btn.addEventListener('touchstart', start, { passive: true });
    btn.addEventListener('mouseup', cancel);
    btn.addEventListener('mouseleave', cancel);
    btn.addEventListener('touchend', cancel);
    btn.addEventListener('touchmove', cancel);
    btn.addEventListener('click', e => {
      if (longPressed) { e.preventDefault(); return; }
      const pid = +btn.dataset.post;
      const p = findPost(pid);
      const cur = p && p.reactions && p.reactions.your_emoji;
      // toggle: если что-то стоит — снимаем, иначе ставим heart
      sendReaction(pid, cur ? null : 'heart');
    });
  });
  // Click on existing reaction pill — toggle that emoji
  document.querySelectorAll('[data-action="react-pill"]').forEach(el => {
    if (el._b) return; el._b = 1;
    el.addEventListener('click', () => {
      const card = el.closest('.post-card');
      const pid = +card.dataset.id;
      const emoji = el.dataset.emoji;
      const p = findPost(pid);
      const cur = p && p.reactions && p.reactions.your_emoji;
      sendReaction(pid, cur === emoji ? null : emoji);
    });
  });
  // Comments
  document.querySelectorAll('[data-action="comment"]').forEach(btn => {
    if (btn._b) return; btn._b = 1;
    btn.addEventListener('click', () => openComments(+btn.dataset.post));
  });
  // NSFW reveal — клик по оверлею показывает контент
  document.querySelectorAll('[data-action="nsfw-reveal"]').forEach(ov => {
    if (ov._b) return; ov._b = 1;
    ov.addEventListener('click', e => {
      e.stopPropagation();
      const card = ov.closest('.post-card');
      if (card) card.classList.add('revealed');
    });
  });
  // Share sheet
  document.querySelectorAll('[data-action="share"]').forEach(btn => {
    if (btn._b) return; btn._b = 1;
    btn.addEventListener('click', e => { e.stopPropagation(); openShareSheet(+btn.dataset.post); });
  });
  // Repost pill: загрузка контактов кто репостнул
  document.querySelectorAll('[data-action="repost-pill"]').forEach(el => {
    if (el._b) return; el._b = 1;
    const pid = +el.dataset.post;
    loadRepostPill(pid, el);
  });
  // Post menu (3 dots)
  document.querySelectorAll('[data-action="menu"]').forEach(btn => {
    if (btn._b) return; btn._b = 1;
    btn.addEventListener('click', e => {
      e.stopPropagation();
      openPostMenu(+btn.dataset.post, btn);
    });
  });
  // Inline-кнопка «Подписаться» в шапке поста
  document.querySelectorAll('[data-action="post-follow"]').forEach(btn => {
    if (btn._b) return; btn._b = 1;
    btn.addEventListener('click', async e => {
      e.stopPropagation();
      if (isGuest()) { guestBlock(); return; }
      const username = btn.dataset.username;
      btn.disabled = true;
      try {
        await api(`/follow/${username}`, 'POST');
        Algo.onFollow(username, true);
        refreshWallet();  // +5 followee (WS прилетит ему; мне как follower — bump если был capped/edge)
        // Помечаем все посты этого автора как «подписан» и убираем кнопки
        feedPosts.forEach(p => { if (p.username === username) p.am_following = true; });
        document.querySelectorAll(`[data-action="post-follow"][data-username="${username}"]`).forEach(b => {
          b.style.transition = 'opacity 0.25s, transform 0.25s';
          b.style.opacity = '0';
          b.style.transform = 'scale(0.7)';
          setTimeout(() => b.remove(), 250);
        });
        showToast(`Подписан на @${username}`);
      } catch(_) { showToast('Ошибка'); btn.disabled = false; }
    });
  });
  // Click on header → profile
  document.querySelectorAll('.post-header').forEach(h => {
    if (h._b) return; h._b = 1;
    h.addEventListener('click', () => openMini(h.dataset.username));
  });
  // Long-press on whole post → menu
  document.querySelectorAll('.post-card').forEach(card => {
    if (card._b) return; card._b = 1;
    let pressTimer = null, pressTarget = null;
    card.addEventListener('touchstart', e => {
      pressTarget = e.target;
      pressTimer = setTimeout(() => {
        // если палец на медиа — показываем меню с «Скачать»
        const mediaEl = pressTarget.closest && pressTarget.closest('.media-el');
        const pid = +card.dataset.id;
        if (mediaEl) {
          openPostMenu(pid, card, mediaEl.dataset.mediaUrl, e.touches[0]);
        } else {
          openPostMenu(pid, card, null, e.touches[0]);
        }
      }, 500);
    }, { passive: true });
    card.addEventListener('touchend', () => { if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; } });
    card.addEventListener('touchmove', () => { if (pressTimer) { clearTimeout(pressTimer); pressTimer = null; } });
    // Desktop right-click on media → menu with download
    card.addEventListener('contextmenu', e => {
      const mediaEl = e.target.closest && e.target.closest('.media-el');
      if (mediaEl) {
        e.preventDefault();
        openPostMenu(+card.dataset.id, card, mediaEl.dataset.mediaUrl, e);
      }
    });
  });
}

function findPost(pid) {
  return feedPosts.find(x => x.id === pid)
      || (window._profPosts || []).find(x => x.id === pid)
      || (window._searchPosts || []).find(x => x.id === pid);
}

async function sendReaction(pid, emoji) {
  if (isGuest()) { guestBlock(); return; }
  try {
    const r = await api(`/react/${pid}`, 'POST', { emoji });
    const p = findPost(pid);
    if (p) {
      p.reactions = r;
      Algo.onReact(p, !!emoji);
    }
    // обновить именно эту карточку
    document.querySelectorAll(`.post-card[data-id="${pid}"]`).forEach(card => {
      const row = card.querySelector('[data-action="reactions-row"]');
      const tog = card.querySelector('[data-action="react-toggle"]');
      if (row && p) row.innerHTML = reactionsHTML(p);
      if (tog) {
        tog.classList.toggle('liked', !!r.your_emoji);
        tog.querySelector('i').className = `fa-${r.your_emoji ? 'solid' : 'regular'} fa-heart`;
      }
    });
    attachEvents(); attachDoubleTap(); loadPreviews(); initAllAudios();
    refreshWallet();  // страховка к WS — для случая когда автор поста = ты сам в другой вкладке
  } catch(e) {}
}

// Dwell-time: засекаем сколько секунд пост был в viewport — сигнал для Algo
const _dwellTimers = new Map();  // pid -> {start, post}
// + Сервер-side трекинг просмотров (для дедупа feed). Дебаунсный batch.
const _viewQueue = new Set();
let _viewFlushTimer = 0;
function _scheduleViewFlush() {
  if (_viewFlushTimer) return;
  _viewFlushTimer = setTimeout(async () => {
    _viewFlushTimer = 0;
    if (!_viewQueue.size) return;
    const ids = [..._viewQueue].slice(0, 50);
    _viewQueue.clear();
    try { await api('/post/view', 'POST', { ids }); } catch(_) {}
  }, 2000);
}

const _dwellObs = new IntersectionObserver(entries => {
  entries.forEach(e => {
    const card = e.target;
    const pid = +card.dataset.id;
    const post = findPost(pid);
    if (!post) return;
    if (e.isIntersecting) {
      if (!_dwellTimers.has(pid)) _dwellTimers.set(pid, { start: performance.now(), post });
      // Сервер view: добавляем в очередь сразу при появлении
      _viewQueue.add(pid);
      _scheduleViewFlush();
    } else {
      const t = _dwellTimers.get(pid);
      if (t) {
        const dwell = performance.now() - t.start;
        if (dwell > 200) Algo.onView(t.post, dwell);
        _dwellTimers.delete(pid);
      }
    }
  });
}, { threshold: 0.6 });

function observeDwell() {
  document.querySelectorAll('.post-card[data-id]').forEach(card => {
    if (!card._dwellObserved) {
      _dwellObs.observe(card);
      card._dwellObserved = true;
    }
  });
}

// При уходе со страницы — flush текущих таймеров
window.addEventListener('beforeunload', () => {
  _dwellTimers.forEach((t, pid) => {
    const dwell = performance.now() - t.start;
    if (dwell > 200) Algo.onView(t.post, dwell);
  });
});

function observeDots() {
  const obs = new IntersectionObserver(entries => {
    entries.forEach(e => {
      if (e.isIntersecting) {
        const id = +e.target.dataset.dot;
        if (!seenIds.has(id)) {
          seenIds.add(id);
          // FIFO cap: после 2000 элементов localStorage начинает квакать (5MB quota).
          // Сбрасываем самые старые.
          const MAX_SEEN = 2000;
          if (seenIds.size > MAX_SEEN) {
            const arr = [...seenIds];
            seenIds = new Set(arr.slice(arr.length - MAX_SEEN));
          }
          try { localStorage.setItem('gs_seen', JSON.stringify([...seenIds])); }
          catch(_) { /* quota — игнорим */ }
          e.target.style.opacity = '0';
          setTimeout(() => e.target.remove(), 400);
        }
        obs.unobserve(e.target);
      }
    });
  }, { threshold: 0.5 });
  document.querySelectorAll('[data-dot]').forEach(el => obs.observe(el));
}

window.addEventListener('scroll', () => {
  const scrolled = scrollY, total = document.body.scrollHeight - innerHeight;
  // Scroll-to-top FAB
  const stb = document.getElementById('scrollTopBtn');
  if (stb) stb.classList.toggle('show', scrolled > 400);
  // Лента: пагинация + окно (windowing)
  if (document.getElementById('screenFeed').classList.contains('active')) {
    if (scrolled > total - 400 && feedHasMore && !feedLoading) loadFeed(true);
    const vis = feedPosts.length - renderStart;
    if (vis > WIN && scrolled > 700) { renderStart = feedPosts.length - WIN; renderFeed(); scrollTo(0, 350); }
  }
  // Профиль: автоподгрузка
  if (document.getElementById('screenFullProfile').classList.contains('active')) {
    if (scrolled > total - 400) loadFpMore();
  }
});

// ── New check ──────────────────────────────────────────────────────────────────

function startNewCheck() { stopNewCheck(); if (currentSort === 'old') return; newInterval = setInterval(checkNew, 5000); }
function stopNewCheck() { if (newInterval) { clearInterval(newInterval); newInterval = null; } }
function hidePill() { document.getElementById('newPill').classList.remove('show'); }

async function checkNew() {
  if (!feedPosts.length || currentSort !== 'new') return;
  const lastId = maxFeedId();
  try {
    const r = await api(`/post/newhere?last_id=${lastId}&sort=${currentSort}`);
    if (!r.has_new) return;
    // Если пользователь наверху — авто-добавляем посты и рисуем разделитель;
    // иначе показываем пилюлю «Новые посты».
    if (window.scrollY < 80) {
      await prependNew();
    } else {
      document.getElementById('newPill').classList.add('show');
    }
  } catch(e) {}
}

async function onNewPill() {
  hidePill();
  const n = await prependNew();
  if (!n) return;
  // Дать DOM-у обновиться, потом скроллим с поправкой на высоту шапки
  requestAnimationFrame(() => {
    const sep = document.getElementById('unreadSep');
    if (sep) scrollToSep(sep);
    else window.scrollTo({top:0, behavior:'smooth'});
  });
}

// ── Confirm dialog ─────────────────────────────────────────────────────────────

function showConfirm({ title = 'Вы уверены?', msg = '', okText = 'Подтвердить', danger = false, onOk }) {
  const overlay = document.getElementById('confirmModal');
  document.getElementById('confirmTitle').textContent = title;
  document.getElementById('confirmMsg').textContent = msg;
  const okBtn = document.getElementById('confirmOk');
  okBtn.textContent = okText;
  okBtn.className = 'confirm-btn ok' + (danger ? ' danger' : '');
  overlay.classList.add('open');
  const close = () => overlay.classList.remove('open');
  const handler = () => { close(); onOk(); };
  okBtn.onclick = handler;
  document.getElementById('confirmCancel').onclick = close;
  overlay.onclick = e => { if (e.target === overlay) close(); };
}

// ── Delete post ────────────────────────────────────────────────────────────────

// ── Edit post ─────────────────────────────────────────────────────────────────
let _editPostId = null;
let _editPostMedia = []; // массив {url, type, name}, изначально копия медиа поста

function openEditPost(postId) {
  const p = findPost(postId);
  if (!p) return;
  _editPostId = postId;
  document.getElementById('editPostText').value = p.content || '';
  _editPostMedia = (p.media || []).map(m => ({ ...m }));
  renderEditPostMedia();
  document.getElementById('editPostErr').textContent = '';
  document.getElementById('editPostBtn').disabled = false;
  document.getElementById('editPostBtn').textContent = 'Сохранить';
  document.getElementById('editPostModal').classList.add('open');
}

function renderEditPostMedia() {
  const list = document.getElementById('editPostMediaList');
  if (!_editPostMedia.length) { list.innerHTML = '<div style="font-size:12px;color:#475569;font-style:italic;">Медиа нет</div>'; return; }
  const icons = { image: 'fa-image', video: 'fa-video', audio: 'fa-music' };
  list.innerHTML = _editPostMedia.map((m, i) => `
    <div class="media-preview-item">
      <div class="media-preview-icon"><i class="fa-solid ${icons[m.type] || 'fa-file'}"></i></div>
      <div class="media-preview-info">
        <div class="media-preview-name">${esc(m.name || m.url.split('/').pop())}</div>
        <div class="media-preview-size">${m.type}</div>
      </div>
      <button class="media-preview-del" onclick="removeEditMedia(${i})" title="Убрать"><i class="fa-solid fa-xmark"></i></button>
    </div>
  `).join('');
}

async function removeEditMedia(idx) {
  if (!await Dialog.confirm('Убрать этот файл? Его нельзя будет вернуть.', { title: 'Удалить медиа', danger: true })) return;
  _editPostMedia.splice(idx, 1);
  renderEditPostMedia();
}

async function submitEditPost() {
  const text = document.getElementById('editPostText').value.trim();
  const errEl = document.getElementById('editPostErr');
  errEl.textContent = '';
  if (!text) { errEl.textContent = 'Текст не может быть пустым'; return; }
  const p = findPost(_editPostId);
  if (!p) return;
  // Что изменилось
  const body = {};
  if (text !== (p.content || '')) body.text = text;
  const oldUrls = (p.media || []).map(m => m.url).sort().join(',');
  const newUrls = _editPostMedia.map(m => m.url).sort().join(',');
  if (oldUrls !== newUrls) body.media = _editPostMedia;
  if (!Object.keys(body).length) { closeModal('editPostModal'); return; }

  const btn = document.getElementById('editPostBtn');
  btn.disabled = true; btn.textContent = '...';
  try {
    await api(`/post/${_editPostId}`, 'PATCH', body);
    // Локально обновим
    if (body.text !== undefined) p.content = body.text;
    if (body.media !== undefined) p.media = _editPostMedia;
    p.edited_at = new Date().toISOString();
    // Пере-отрисуем карточку
    document.querySelectorAll(`.post-card[data-id="${_editPostId}"]`).forEach(card => {
      card.outerHTML = postHTML(p);
    });
    attachEvents(); attachDoubleTap(); loadPreviews(); initAllAudios();
    closeModal('editPostModal');
    showToast('Пост обновлён');
  } catch(e) {
    errEl.textContent = e.message || 'Ошибка сохранения';
    btn.disabled = false; btn.textContent = 'Сохранить';
  }
}

async function mintPostAsNft(postId) {
  const supplyRaw = await Dialog.prompt('Тираж NFT (100-10000):', '100',
    { title: 'Создать NFT — шаг 1/4', placeholder: 'число', okText: 'Далее' });
  if (supplyRaw == null) return;
  const supply = +supplyRaw;
  if (!supply || supply < 100) return;
  const priceRaw = await Dialog.prompt('Цена за штуку в Soul:', '5',
    { title: 'Создать NFT — шаг 2/4', placeholder: 'число', okText: 'Далее' });
  if (priceRaw == null) return;
  const price = +priceRaw;
  if (!price || price < 1) return;
  const autoBuyRaw = await Dialog.prompt(
    `Сколько штук выкупить себе (0-${supply})?\nПолучите Soul за каждую (если в системе хватает).`,
    '0',
    { title: 'Создать NFT — шаг 3/4', placeholder: 'число', okText: 'Далее' }
  );
  if (autoBuyRaw == null) return;
  const autoBuy = +autoBuyRaw || 0;
  const emojiRaw = await Dialog.prompt('Эмодзи (1-2 символа, можно пропустить):', '',
    { title: 'Создать NFT — шаг 4/4', maxLength: 4, okText: 'Далее' });
  if (emojiRaw == null) return;
  const emoji = emojiRaw.trim();
  const supplyFee = Math.max(1, Math.round((10000 / supply) ** 1.1));
  const gostCost = 50 + supplyFee;
  const ok = await Dialog.confirm(
    `Тираж: ${supply}\nЦена в маркете: ${price} Soul\nАвтовыкуп: ${autoBuy} шт\n\nСтоимость создания: ${gostCost} Gost\nПолучите за автовыкуп: ${autoBuy * price} Soul`,
    { title: 'Создать NFT из поста?', okText: 'Создать' }
  );
  if (!ok) return;
  try {
    const r = await api('/post/mint_as_nft', 'POST', {
      post_id: postId, supply, sell_price_soul: price, auto_buy: autoBuy,
      image_emoji: emoji || null, bg_color: null,
    });
    showToast(`NFT создан! −${r.gost_paid} Gost${r.soul_received ? ', +' + r.soul_received + ' Soul' : ''}`);
  } catch(e) { showToast(e.message || 'Ошибка минта', true); }
}

function deletePost(postId) {
  showConfirm({
    title: 'Удалить пост?',
    msg: 'Это действие нельзя отменить. Пост и все медиафайлы будут удалены.',
    okText: 'Удалить',
    danger: true,
    onOk: async () => {
      try {
        await api(`/post/${postId}`, 'DELETE');
        feedPosts = feedPosts.filter(p => p.id !== postId);
        const el = document.querySelector(`[data-id="${postId}"]`);
        if (el) { el.style.opacity = '0'; el.style.transition = 'opacity 0.3s'; setTimeout(() => el.remove(), 300); }
        showToast('Пост удалён');
      } catch(e) { showToast('Ошибка при удалении'); }
    }
  });
}

// ── Notifications ───────────────────────────────────────────────────────────────

let notifOffset = 0, notifLoaded = false;

async function loadNotifications(append = false) {
  const list = document.getElementById('notifList');
  if (!append) {
    notifOffset = 0; notifLoaded = false;
    list.innerHTML = '<div class="loader"><div class="spinner"></div></div>';
  }
  try {
    const d = await api(`/notif?offset=${notifOffset}`);
    notifOffset += d.notifications.length;
    notifLoaded = !d.has_more;
    const html = d.notifications.map(notifHTML).join('');
    if (!append) {
      list.innerHTML = html || '<div class="empty"><i class="fa-solid fa-bell-slash"></i><p>Уведомлений пока нет</p></div>';
    } else {
      list.innerHTML += html;
    }
    if (d.has_more) {
      list.innerHTML += `<button class="load-more-btn" onclick="loadNotifications(true)">Загрузить ещё</button>`;
    }
    // mark as read when tab opened
    await api('/notif/read', 'POST');
    updateNotifBadge(0);
  } catch(e) {
    if (!append) list.innerHTML = '<div class="empty"><i class="fa-solid fa-triangle-exclamation"></i><p>Ошибка загрузки</p></div>';
  }
}

function notifHTML(n) {
  const actor = `<b>${esc(n.actor_name)}</b> <span style="color:#475569">@${esc(n.actor_username)}</span>`;
  let icon, text, preview = '';
  switch (n.type) {
    case 'react': {
      // preview здесь это ключ эмодзи (heart/fire/...)
      const emoKey = n.preview && EMOJI[n.preview] ? n.preview : 'heart';
      icon = `<span class="notif-icon like">${emojiSvg(emoKey)}</span>`;
      text = `${actor} отреагировал на ваш пост`;
      break;
    }
    case 'comment':
      icon = '<span class="notif-icon comment"><i class="fa-solid fa-comment"></i></span>';
      text = `${actor} прокомментировал ваш пост`;
      if (n.preview) preview = `<div class="notif-preview">${esc(n.preview)}</div>`;
      break;
    case 'mention':
      icon = '<span class="notif-icon comment" style="background:rgba(168,85,247,0.85);"><i class="fa-solid fa-at"></i></span>';
      text = `${actor} упомянул вас`;
      if (n.preview) preview = `<div class="notif-preview">${esc(n.preview)}</div>`;
      break;
    case 'new_post':
      icon = '<span class="notif-icon" style="background:rgba(168,85,247,0.85);color:#fff;"><i class="fa-solid fa-pen"></i></span>';
      text = `${actor} опубликовал новый пост`;
      if (n.preview) preview = `<div class="notif-preview">${esc(n.preview)}</div>`;
      break;
    case 'follow':
      icon = '<span class="notif-icon" style="background:linear-gradient(135deg,var(--primary),var(--primary2));color:#fff;"><i class="fa-solid fa-user-plus"></i></span>';
      text = `${actor} подписался на вас`;
      break;
    case 'like':  // legacy
      icon = '<span class="notif-icon like"><i class="fa-solid fa-heart"></i></span>';
      text = `${actor} лайкнул ваш пост`;
      break;
    default:
      icon = '<span class="notif-icon comment"><i class="fa-solid fa-bell"></i></span>';
      text = `${actor}: ${esc(n.type)}`;
      if (n.preview) preview = `<div class="notif-preview">${esc(n.preview)}</div>`;
  }
  const click = n.type === 'follow'
    ? `openFullProfile(${jsAttr(n.actor_username)})`
    : `goToPost(${Number(n.post_id) || 0})`;
  return `<div class="notif-card${n.is_read ? '' : ' unread'}" onclick="${click}">
    <div class="notif-av">${ini(n.actor_name)}${icon}</div>
    <div class="notif-body">
      <div class="notif-text">${text}</div>
      ${preview}
      <div class="notif-time">${ago(n.created_at)}</div>
    </div>
  </div>`;
}

function goToPost(postId) {
  // switch to feed and scroll to post if loaded, else just go to feed
  document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById('navFeed').classList.add('active');
  document.getElementById('screenFeed').classList.add('active');
  startNewCheck();
  const el = document.querySelector(`[data-id="${postId}"]`);
  if (el) { el.scrollIntoView({ behavior: 'smooth', block: 'center' }); }
}

function updateNotifBadge(count) {
  const txt = count > 99 ? '99+' : String(count);
  ['notifBadge', 'dtNotifBadge'].forEach(id => {
    const b = document.getElementById(id);
    if (!b) return;
    b.textContent = txt;
    b.classList.toggle('show', count > 0);
  });
}

let notifCheckInterval = null;
function startNotifCheck() {
  if (notifCheckInterval) return;
  notifCheckInterval = setInterval(() => { checkNotifCount(); checkChatUnread(); }, 15000);
  checkNotifCount();
  checkChatUnread();
}
async function checkNotifCount() {
  try {
    const d = await api('/notif/unread');
    updateNotifBadge(d.count);
  } catch(e) {}
}
async function checkChatUnread() {
  try {
    const r = await fetch('/api/chat/unread', { headers: { Authorization: 'Bearer ' + token } });
    if (!r.ok) return;
    const d = await r.json();
    updateChatBadge(d.count || 0);
  } catch(e) {}
}
function updateChatBadge(c) {
  const txt = c > 99 ? '99+' : String(c);
  ['dtChatBadge', 'profChatBadge'].forEach(id => {
    const b = document.getElementById(id);
    if (!b) return;
    b.textContent = txt;
    b.classList.toggle('show', c > 0);
  });
}

// ── Attach media ───────────────────────────────────────────────────────────────

document.getElementById('attachBtn').addEventListener('click', e => {
  const isMsk = document.getElementById('miniskaToggle').checked;
  if (isMsk) {
    // В режиме миниски — только одно видео без меню
    if (attachedFiles.length >= 1) { showToast('Уже одно видео — больше нельзя'); return; }
    pickFile('video');
    return;
  }
  if (attachedFiles.length >= 5) { showToast('Максимум 5 файлов'); return; }
  const overlay = document.getElementById('attachOverlay');
  const menu = document.getElementById('attachMenu');
  overlay.classList.add('open');
  const btn = e.currentTarget.getBoundingClientRect();
  menu.style.left = btn.left + 'px';
  menu.style.bottom = (window.innerHeight - btn.top + 8) + 'px';
  menu.style.top = 'auto';
});
document.getElementById('attachOverlay').addEventListener('click', function(e) {
  if (e.target === this) this.classList.remove('open');
});

const ACCEPT = { image: 'image/jpeg,image/png,image/gif,image/webp', video: 'video/mp4,video/webm,video/quicktime', audio: 'audio/mpeg,audio/wav,audio/ogg,audio/mp4' };
const MAX_SIZE = { image: 30 * 1024 * 1024, video: 50 * 1024 * 1024, audio: 15 * 1024 * 1024 };
const MAX_LABEL = { image: '30MB', video: '50MB', audio: '15MB' };

function pickFile(type) {
  document.getElementById('attachOverlay').classList.remove('open');
  currentPickType = type;
  const inp = document.getElementById('fileInput');
  inp.accept = ACCEPT[type]; inp.removeAttribute('capture'); inp.value = '';
  if (type === 'video') showToast('Для видео используй файловый менеджер');
  inp.click();
}

document.getElementById('fileInput').addEventListener('change', async function() {
  const file = this.files[0];
  if (!file) return;
  const ext = file.name.split('.').pop().toLowerCase();
  const allowed = { image: ['jpg','jpeg','png','gif','webp'], video: ['mp4','webm','mov'], audio: ['mp3','wav','ogg','m4a'] };
  if (!allowed[currentPickType].includes(ext)) { showToast('Недопустимый тип файла'); return; }
  if (file.size > MAX_SIZE[currentPickType]) { showToast(`Максимум ${MAX_LABEL[currentPickType]}`); return; }
  if (attachedFiles.length >= 5) { showToast('Максимум 5 файлов'); return; }
  const fd = new FormData(); fd.append('file', file);
  showToast('Загрузка...');
  try {
    const r = await fetch(API + '/upload', { method: 'POST', headers: { Authorization: 'Bearer ' + token }, body: fd });
    if (!r.ok) throw new Error(await r.text());
    const data = await r.json();
    attachedFiles.push({ ...data, localName: file.name, localSize: file.size });
    renderMediaPreview(); updatePubBtn(); showToast('Файл прикреплён');
  } catch(e) { showToast('Ошибка загрузки файла'); }
});

function renderMediaPreview() {
  const list = document.getElementById('mediaPreviewList');
  if (!attachedFiles.length) { list.innerHTML = ''; return; }
  const icons = { image: 'fa-image', video: 'fa-video', audio: 'fa-music' };
  list.innerHTML = '<div class="media-preview-list">' + attachedFiles.map((f, i) => `
    <div class="media-preview-item">
      <div class="media-preview-icon"><i class="fa-solid ${icons[f.type] || 'fa-file'}"></i></div>
      <div class="media-preview-info">
        <div class="media-preview-name">${esc(f.localName || f.name)}</div>
        <div class="media-preview-size">${((f.localSize || 0) / 1024 / 1024).toFixed(1)} MB</div>
      </div>
      <button class="media-preview-del" onclick="removeMedia(${i})"><i class="fa-solid fa-xmark"></i></button>
    </div>
  `).join('') + '</div>';
}

async function removeMedia(idx) {
  if (!await Dialog.confirm('Удалить этот файл?', { title: 'Убрать вложение', danger: true })) return;
  attachedFiles.splice(idx, 1); renderMediaPreview(); updatePubBtn();
}

function updatePubBtn() {
  const isMsk = document.getElementById('miniskaToggle') && document.getElementById('miniskaToggle').checked;
  if (isMsk) {
    const hasVideo = attachedFiles.length === 1 && attachedFiles[0].type === 'video';
    const validTags = _miniskaTags().filter(t => t.length >= 2);
    document.getElementById('pubBtn').disabled = !(hasVideo && validTags.length >= MSK_TAG_MIN);
  } else {
    document.getElementById('pubBtn').disabled = document.getElementById('postText').value.trim().length === 0;
  }
}

// ── Create post ────────────────────────────────────────────────────────────────

const postText = document.getElementById('postText');
const charCount = document.getElementById('charCount');
const pubBtn = document.getElementById('pubBtn');
postText.addEventListener('input', () => {
  const l = postText.value.length;
  charCount.textContent = l + ' / 1000';
  charCount.classList.toggle('warn', l > 800);
  updatePubBtn();
});
// ── Poll editor (создание опроса) ─────────────────────────────────────────────
let _pollDraft = null; // { question, options: ['',''], is_quiz, correct_idx }

document.getElementById('pollBtn').addEventListener('click', () => {
  if (_pollDraft) { _pollDraft = null; renderPollEditor(); return; }
  _pollDraft = { question: '', options: ['', ''], is_quiz: false, correct_idx: null };
  renderPollEditor();
});

function renderPollEditor() {
  const wrap = document.getElementById('pollEditor');
  document.getElementById('pollBtn').classList.toggle('attached', !!_pollDraft);
  if (!_pollDraft) { wrap.innerHTML = ''; return; }
  const d = _pollDraft;
  const opts = d.options.map((opt, i) => `
    <div class="poll-opt-row">
      ${d.is_quiz ? `<button class="quiz-check${d.correct_idx === i ? ' checked' : ''}" onclick="pollSetCorrect(${i})" title="Правильный"><i class="fa-solid fa-check"></i></button>` : ''}
      <input type="text" maxlength="80" placeholder="Вариант ${i + 1}" value="${esc(opt)}" oninput="pollSetOpt(${i}, this.value)">
      ${d.options.length > 2 ? `<button class="opt-del" onclick="pollDelOpt(${i})" title="Убрать"><i class="fa-solid fa-xmark"></i></button>` : ''}
    </div>
  `).join('');
  wrap.innerHTML = `
    <div class="poll-editor">
      <div class="poll-editor-head">
        <div class="poll-editor-title"><i class="fa-solid fa-chart-simple"></i> ${d.is_quiz ? 'Викторина' : 'Опрос'}</div>
        <button class="poll-remove" onclick="_pollDraft=null;renderPollEditor()" title="Убрать"><i class="fa-solid fa-trash-can"></i></button>
      </div>
      <input type="text" maxlength="200" placeholder="Вопрос" value="${esc(d.question)}" oninput="_pollDraft.question = this.value">
      ${opts}
      <div class="poll-editor-actions">
        ${d.options.length < 6 ? `<button class="poll-add-opt" onclick="pollAddOpt()"><i class="fa-solid fa-plus"></i> Добавить вариант</button>` : ''}
        <label class="poll-quiz-toggle">
          <input type="checkbox" ${d.is_quiz ? 'checked' : ''} onchange="pollToggleQuiz(this.checked)">
          Викторина
        </label>
      </div>
    </div>`;
}
function pollSetOpt(i, v) { _pollDraft.options[i] = v; }
function pollAddOpt() { _pollDraft.options.push(''); renderPollEditor(); }
function pollDelOpt(i) {
  _pollDraft.options.splice(i, 1);
  if (_pollDraft.correct_idx === i) _pollDraft.correct_idx = null;
  else if (_pollDraft.correct_idx > i) _pollDraft.correct_idx--;
  renderPollEditor();
}
function pollSetCorrect(i) { _pollDraft.correct_idx = i; renderPollEditor(); }
function pollToggleQuiz(on) {
  _pollDraft.is_quiz = on;
  if (!on) _pollDraft.correct_idx = null;
  renderPollEditor();
}

pubBtn.addEventListener('click', async () => {
  const isMiniska = document.getElementById('miniskaToggle').checked;
  const content = postText.value.trim();

  // ── Ветка миниски ──
  if (isMiniska) {
    const v = _validateMiniska();
    if (!v.ok) { showToast(v.err); return; }
    pubBtn.disabled = true; pubBtn.textContent = '...';
    try {
      const video = attachedFiles[0];
      const caption = (content + ' ' + v.tags.map(t => '#' + t).join(' ')).trim();
      await api('/miniska/new', 'POST', { caption, video_url: video.url }, { timeout: 90000 });
      postText.value = ''; charCount.textContent = '0 / 1000'; attachedFiles = []; renderMediaPreview();
      resetMiniskaTags();
      document.getElementById('miniskaToggle').checked = false;
      onMiniskaToggle(false);
      showToast('Миниска опубликована!');
      switchScreen('screenMinisky');
      loadMinisky(true);
    } catch(e) { showToast(e.message || 'Ошибка публикации'); }
    pubBtn.disabled = false; pubBtn.textContent = 'Опубликовать';
    return;
  }

  // ── Обычный пост ──
  if (!content) return;
  let pollPayload = null;
  if (_pollDraft) {
    const q = (_pollDraft.question || '').trim();
    const opts = (_pollDraft.options || []).map(o => (o || '').trim()).filter(Boolean);
    if (!q) { showToast('Вопрос опроса пустой'); return; }
    if (opts.length < 2) { showToast('Опрос: минимум 2 варианта'); return; }
    if (_pollDraft.is_quiz && (_pollDraft.correct_idx === null || _pollDraft.correct_idx === undefined || _pollDraft.correct_idx >= opts.length)) {
      showToast('Викторина: отметьте правильный ответ'); return;
    }
    pollPayload = {
      question: q, options: opts,
      is_quiz: !!_pollDraft.is_quiz,
      correct_idx: _pollDraft.is_quiz ? _pollDraft.correct_idx : null,
    };
  }
  pubBtn.disabled = true; pubBtn.textContent = '...';
  try {
    const mediaPayload = attachedFiles.length ? attachedFiles.map(f => ({ url: f.url, type: f.type, name: f.name })) : null;
    const nsfwEl = document.getElementById('nsfwToggle');
    const body = { text: content, media: mediaPayload, is_nsfw: !!(nsfwEl && nsfwEl.checked) };
    if (pollPayload) body.poll = pollPayload;
    // С медиа сервер может долго обрабатывать (Pillow/ffmpeg) — таймаут больше
    const _to = attachedFiles.length ? 60000 : 20000;
    const r = await api('/post/new', 'POST', body, { timeout: _to });
    postText.value = ''; charCount.textContent = '0 / 1000'; attachedFiles = []; renderMediaPreview();
    _pollDraft = null; renderPollEditor();
    const _nsfwEl = document.getElementById('nsfwToggle'); if (_nsfwEl) _nsfwEl.checked = false;
    showToast('Пост опубликован!');
    refreshWallet();  // +5 Gost за свой пост (WS придёт сам; это страховка)
    document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
    document.getElementById('navFeed').classList.add('active');
    document.getElementById('screenFeed').classList.add('active');
    currentSort = 'new';
    document.querySelectorAll('.filter-btn').forEach(b => b.classList.toggle('active', b.dataset.sort === 'new'));
    resetFeed(); await loadFeed();
    const el = document.querySelector(`[data-id="${r.post_id}"]`);
    if (el) el.scrollIntoView({ behavior: 'smooth', block: 'center' });
    startNewCheck();
  } catch(e) { showToast(e.message || 'Ошибка публикации'); }
  pubBtn.disabled = false; pubBtn.textContent = 'Опубликовать';
});

// ── Audio player ───────────────────────────────────────────────────────────────

const audioPlayers = {};

// Стабильный id виджета по URL (чтобы при ре-рендере не пересоздавать плеер)
function audId(url){
  let h = 5381;
  for (let i = 0; i < url.length; i++) h = ((h * 33) ^ url.charCodeAt(i)) | 0;
  return 'aud_' + Math.abs(h).toString(36);
}

// Псевдослучайный waveform по URL — детерминированный, без декодирования файла.
// Telegram делает похожее когда не успел декодировать настоящие пики.
function _mulberry32(seed){ return () => { let t = seed += 0x6D2B79F5; t = Math.imul(t ^ t>>>15, t | 1); t ^= t + Math.imul(t ^ t>>>7, t | 61); return ((t ^ t>>>14) >>> 0) / 4294967296; }; }
function genWave(url, n=50){
  let s = 0; for (let i = 0; i < url.length; i++) s = ((s<<5) - s + url.charCodeAt(i)) | 0;
  const r = _mulberry32(s || 1);
  // Базовая высота + случайный шум + затухание к краям для лёгкой "капсульности"
  return Array.from({length:n}, (_, i) => {
    const edge = Math.min(i, n-1-i) / (n/2);  // 0 у краёв, 1 в центре
    const env = 0.35 + edge * 0.55;
    return Math.max(0.18, Math.min(1, env * (0.55 + r() * 0.7)));
  });
}

// Инициализация плеера — грузит metadata сразу для отображения длительности
function initAudio(id, url){
  if (audioPlayers[id]) { updateAudioUI(id); return; }
  const a = new Audio();
  a.preload = 'metadata';
  audioPlayers[id] = a;
  a.addEventListener('timeupdate', () => updateAudioUI(id));
  a.addEventListener('loadedmetadata', () => updateAudioUI(id));
  a.addEventListener('durationchange', () => updateAudioUI(id));
  a.addEventListener('ended', () => {
    _setAudioBtn(id, false);
    a.currentTime = 0;
    updateAudioUI(id);
  });
  a.src = url;
}

// Обходим все аудио на странице и инициализируем — таймер появится без play
function initAllAudios(){
  document.querySelectorAll('.audio-widget[data-audio-id]').forEach(el => {
    initAudio(el.dataset.audioId, el.dataset.audioUrl);
    // Сразу применим UI (если плеер уже был — отрисует прогресс/played-столбики)
    updateAudioUI(el.dataset.audioId);
  });
}

function _setAudioBtn(id, playing) {
  document.querySelectorAll(`.audio-widget[data-audio-id="${id}"] .audio-play-btn`).forEach(b => {
    const i = b.querySelector('i');
    if (i) i.className = playing ? 'fa-solid fa-pause' : 'fa-solid fa-play';
    b.classList.toggle('playing', playing);
  });
}

function toggleAudio(id, url) {
  initAudio(id, url);
  const a = audioPlayers[id];
  if (a.paused) {
    // Пауза всех остальных
    Object.entries(audioPlayers).forEach(([oid, oa]) => {
      if (oid !== id && !oa.paused) {
        oa.pause();
        _setAudioBtn(oid, false);
      }
    });
    a.play().catch(()=>{});
    _setAudioBtn(id, true);
  } else {
    a.pause();
    _setAudioBtn(id, false);
  }
}

function updateAudioUI(id) {
  const a = audioPlayers[id]; if (!a) return;
  const dur = isFinite(a.duration) ? a.duration : 0;
  const cur = a.currentTime || 0;
  const pct = dur ? cur / dur : 0;
  // Один и тот же аудиовиджет может присутствовать на нескольких экранах
  // (лента + профиль + поиск) — обновляем ВСЕ копии
  document.querySelectorAll(`.audio-widget[data-audio-id="${id}"]`).forEach(w => {
    const time = w.querySelector('.audio-time');
    if (time) {
      if (cur > 0) time.textContent = fmtTime(cur) + ' / ' + fmtTime(dur);
      else time.textContent = fmtTime(dur);
    }
    const wf = w.querySelector('.audio-waveform');
    if (wf) {
      const bars = wf.children;
      const playedCount = Math.round(pct * bars.length);
      for (let i = 0; i < bars.length; i++) {
        bars[i].classList.toggle('played', i < playedCount);
      }
    }
  });
}

function seekAudio(id, e) {
  const a = audioPlayers[id];
  if (!a) { initAudio(id, document.querySelector(`[data-audio-id="${id}"]`)?.dataset.audioUrl); return; }
  if (!a.duration || !isFinite(a.duration)) return;
  const rect = e.currentTarget.getBoundingClientRect();
  const pct = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
  a.currentTime = pct * a.duration;
  updateAudioUI(id);
}

// ── Fullscreen viewer ──────────────────────────────────────────────────────────

let viewerVideo = null;
function openViewer(url, type) {
  const overlay = document.getElementById('viewerOverlay');
  const body = document.getElementById('viewerBody');
  const controls = document.getElementById('viewerControls');
  overlay.classList.add('open'); viewerUrl = url;
  document.getElementById('viewerDl').onclick = () => downloadFile(url);
  if (type === 'image') {
    body.innerHTML = `<img class="viewer-img" src="${esc(url)}">`;
    controls.style.display = 'none'; viewerVideo = null;
  } else {
    body.innerHTML = `<video class="viewer-video" src="${esc(url)}" playsinline></video>`;
    viewerVideo = body.querySelector('video');
    controls.style.display = 'block';
    viewerVideo.play();
    document.getElementById('viewerPlay').querySelector('i').className = 'fa-solid fa-pause';
    viewerVideo.addEventListener('timeupdate', updateViewerUI);
    viewerVideo.addEventListener('ended', () => { document.getElementById('viewerPlay').querySelector('i').className = 'fa-solid fa-play'; });
  }
}
function closeViewer() {
  document.getElementById('viewerOverlay').classList.remove('open');
  if (viewerVideo) { viewerVideo.pause(); viewerVideo = null; }
  document.getElementById('viewerBody').innerHTML = '';
}
function updateViewerUI() {
  if (!viewerVideo) return;
  const pct = viewerVideo.duration ? viewerVideo.currentTime / viewerVideo.duration * 100 : 0;
  document.getElementById('viewerFill').style.width = pct + '%';
  document.getElementById('viewerTimer').textContent = fmtTime(viewerVideo.currentTime) + ' / ' + fmtTime(viewerVideo.duration || 0);
}
document.getElementById('viewerPlay').addEventListener('click', () => {
  if (!viewerVideo) return;
  if (viewerVideo.paused) { viewerVideo.play(); document.getElementById('viewerPlay').querySelector('i').className = 'fa-solid fa-pause'; }
  else { viewerVideo.pause(); document.getElementById('viewerPlay').querySelector('i').className = 'fa-solid fa-play'; }
});
document.getElementById('viewerTimeline').addEventListener('click', e => {
  if (!viewerVideo || !viewerVideo.duration) return;
  const rect = e.currentTarget.getBoundingClientRect();
  viewerVideo.currentTime = (e.clientX - rect.left) / rect.width * viewerVideo.duration;
});

// ── Context menu ───────────────────────────────────────────────────────────────

function buildMenuItems(items) {
  const menu = document.getElementById('ctxMenu');
  menu.innerHTML = items.map((it, i) =>
    `<div class="ctx-item${it.danger ? ' danger' : ''}" data-idx="${i}"><i class="fa-solid ${it.icon}"></i>${esc(it.label)}</div>`
  ).join('');
  menu.querySelectorAll('.ctx-item').forEach(el => {
    el.addEventListener('click', () => {
      menu.classList.remove('open');
      const idx = +el.dataset.idx;
      if (items[idx] && items[idx].onClick) items[idx].onClick();
    });
  });
}

function positionMenu(e) {
  const menu = document.getElementById('ctxMenu');
  menu.classList.add('open');
  const x = e.clientX || e.pageX || (e.touches && e.touches[0] && e.touches[0].clientX) || 100;
  const y = e.clientY || e.pageY || (e.touches && e.touches[0] && e.touches[0].clientY) || 100;
  menu.style.left = Math.min(x, window.innerWidth - 180) + 'px';
  menu.style.top = Math.min(y, window.innerHeight - 200) + 'px';
}

// Открыть меню поста. Если mediaUrl передан — добавит «Скачать».
function openPostMenu(postId, anchor, mediaUrl, eventOrEl) {
  const p = findPost(postId);
  const isOwn = me && p && p.user_id === me.id;
  const items = [];
  if (mediaUrl) {
    items.push({ icon: 'fa-download', label: 'Скачать', onClick: () => downloadFile(mediaUrl) });
  }
  items.push({ icon: 'fa-link', label: 'Скопировать ссылку', onClick: () => copyPostLink(postId) });
  items.push({ icon: 'fa-share-nodes', label: 'Поделиться', onClick: () => sharePost(postId) });
  items.push({ icon: 'fa-image', label: 'Сохранить картинкой', onClick: () => savePostAsImage(postId) });
  if (!isGuest()) {
    items.push({ icon: 'fa-comment', label: 'Отправить в GhostChat', onClick: () => sharePostToChat(postId) });
  }
  if (!isOwn && !isGuest()) {
    items.push({ icon: 'fa-eye-slash', label: 'Не интересно', onClick: () => hidePostForMe(postId) });
    if (p && p.username) {
      items.push({ icon: 'fa-user-slash', label: `Скрыть @${p.username}`, onClick: () => blockAuthor(p.username) });
    }
    items.push({ icon: 'fa-flag', label: 'Пожаловаться', danger: true, onClick: () => openReportSheet(postId) });
  }
  if (isOwn) {
    items.push({ icon: 'fa-pen', label: 'Редактировать', onClick: () => openEditPost(postId) });
    items.push({ icon: 'fa-gem', label: 'Минтить как NFT', onClick: () => mintPostAsNft(postId) });
    items.push({ icon: 'fa-chart-line', label: 'Видимость + overwatch', onClick: () => openPostActivity(postId) });
    items.push({ icon: 'fa-trash-can', label: 'Удалить пост', danger: true, onClick: () => deletePost(postId) });
  } else if (me && me.is_admin) {
    // Admin может смотреть activity и заказывать overwatch на любые посты
    items.push({ icon: 'fa-chart-line', label: 'Видимость (админ)', onClick: () => openPostActivity(postId) });
  }
  buildMenuItems(items);
  // позиционирование — около anchor, или по event
  const ev = (eventOrEl && (eventOrEl.clientX != null || eventOrEl.touches)) ? eventOrEl : anchor.getBoundingClientRect();
  if (ev.clientX != null) positionMenu(ev);
  else if (ev.left != null) positionMenu({ clientX: ev.left, clientY: ev.bottom + 8 });
  else positionMenu({ clientX: 100, clientY: 100 });
}

document.addEventListener('click', e => {
  // не закрывать при клике внутри меню или палитры эмодзи или триггера реакции
  const t = e.target;
  if (!t.closest) return;
  if (t.closest('#ctxMenu')) return;
  if (t.closest('.emoji-bar')) return;
  if (t.closest('.react-trigger')) return; // клик по сердцу не должен сразу закрывать палитру
  document.getElementById('ctxMenu').classList.remove('open');
  closeEmojiPalette();
});

function downloadFile(url) {
  const a = document.createElement('a'); a.href = url; a.download = url.split('/').pop(); document.body.appendChild(a); a.click(); a.remove();
}

// ── Sharing ─────────────────────────────────────────────────────────────────────

function buildPostUrl(postId) {
  // Каноничный URL с OG-превью. /p/{id} серверно отдаёт og:* meta и
  // редиректит на /social/?p={id} для открытия в приложении.
  return location.origin + '/p/' + postId;
}

function buildUserUrl(username) {
  // Каноничный URL с OG-превью для профиля.
  return location.origin + '/u/' + encodeURIComponent(username);
}

function buildWrappedUrl(username) {
  return location.origin + '/wrapped/' + encodeURIComponent(username);
}

async function copyPostLink(postId) {
  const url = buildPostUrl(postId);
  try {
    await navigator.clipboard.writeText(url);
    showToast('Ссылка скопирована');
  } catch(e) {
    // fallback
    const ta = document.createElement('textarea');
    ta.value = url; document.body.appendChild(ta); ta.select();
    try { document.execCommand('copy'); showToast('Ссылка скопирована'); }
    catch(e2) { showToast('Не удалось скопировать'); }
    ta.remove();
  }
}

// Шаринг поста в GhostChat — модалка с контактами + поиском
async function sharePostToChat(postId) {
  const p = findPost(postId);
  if (!p) return;
  _sharePostId = postId;
  document.getElementById('shareModal').classList.add('open');
  document.getElementById('shareSearch').value = '';
  await loadShareContacts();
  setTimeout(() => document.getElementById('shareSearch').focus(), 100);
}

let _sharePostId = null;
let _shareContacts = [];

async function loadShareContacts(){
  const list = document.getElementById('shareList');
  list.innerHTML = '<div style="padding:30px;text-align:center;color:var(--muted);font-size:13px;">Загрузка контактов…</div>';
  try {
    const r = await fetch('/api/chat/contacts', { headers: { Authorization: 'Bearer ' + token } });
    _shareContacts = r.ok ? await r.json() : [];
  } catch(_) { _shareContacts = []; }
  renderShareList(_shareContacts, true);
}

function renderShareList(items, fromContacts){
  const list = document.getElementById('shareList');
  if (!items.length) {
    list.innerHTML = fromContacts
      ? '<div style="padding:30px;text-align:center;color:#475569;font-size:13px;">Контактов пока нет.<br>Введите @username чтобы найти.</div>'
      : '<div style="padding:30px;text-align:center;color:#475569;font-size:13px;">Никого не найдено</div>';
    return;
  }
  const label = fromContacts
    ? '<div style="font-size:11px;color:var(--sub);font-weight:700;letter-spacing:0.6px;text-transform:uppercase;padding:6px 4px 10px;">Контакты</div>'
    : '<div style="font-size:11px;color:var(--sub);font-weight:700;letter-spacing:0.6px;text-transform:uppercase;padding:6px 4px 10px;">Найдено</div>';
  list.innerHTML = label + items.map(u => `
    <div class="m-user" onclick="shareSendTo(${jsAttr(u.username)}, ${fromContacts ? 'false' : 'true'})" style="position:relative;">
      <div class="av">${ini(u.display_name)}</div>
      <div class="info"><div class="nm">${esc(u.display_name)}</div><div class="un">@${esc(u.username)}</div></div>
      <div style="display:flex;align-items:center;gap:8px;flex-shrink:0;">
        ${fromContacts ? '' : '<span style="font-size:10px;color:var(--primary);background:rgba(168,85,247,0.12);border:1px solid rgba(168,85,247,0.25);padding:3px 8px;border-radius:999px;font-weight:700;letter-spacing:0.3px;">+ В КОНТАКТЫ</span>'}
        <i class="fa-solid fa-paper-plane" style="color:var(--primary);font-size:14px;"></i>
      </div>
    </div>
  `).join('');
}

let _shareSearchTimer = 0;
function _shareOnSearch(q){
  clearTimeout(_shareSearchTimer);
  q = q.trim();
  if (!q) { renderShareList(_shareContacts, true); return; }
  // Сначала фильтруем контакты локально
  const ql = q.toLowerCase().replace(/^@/, '');
  const local = _shareContacts.filter(c =>
    c.username.toLowerCase().includes(ql) ||
    (c.display_name && c.display_name.toLowerCase().includes(ql))
  );
  if (local.length) { renderShareList(local, true); return; }
  // Иначе ищем юзеров через soc-поиск
  _shareSearchTimer = setTimeout(async () => {
    try {
      const d = await api(`/search?q=@${encodeURIComponent(ql)}`);
      const found = (d.results || []).filter(u => u.username !== me.username);
      renderShareList(found, false);
    } catch(_) {
      document.getElementById('shareList').innerHTML = '<div style="padding:30px;text-align:center;color:var(--red);font-size:13px;">Ошибка поиска</div>';
    }
  }, 250);
}

async function shareSendTo(username, addToContacts){
  if (!_sharePostId) return;
  const p = findPost(_sharePostId);
  if (!p) return;
  const url = buildPostUrl(_sharePostId);
  const previewText = `${p.display_name} (@${p.username}): ${(p.content || '').slice(0, 80)}${(p.content || '').length > 80 ? '…' : ''}\n${url}`;
  showToast('Открываем чат…');
  if (addToContacts) {
    try {
      const r = await fetch(`/api/chat/contacts/${encodeURIComponent(username)}`, { method: 'POST', headers: { Authorization: 'Bearer ' + token } });
      if (!r.ok) console.warn('add contact failed', await r.text());
    } catch(e) { console.warn('add contact error', e); }
  }
  closeModal('shareModal');
  location.href = `/chat/?to=${encodeURIComponent(username)}&text=${encodeURIComponent(previewText)}&from=${encodeURIComponent(location.pathname + location.search)}`;
}

async function sharePost(postId) {
  const url = buildPostUrl(postId);
  const p = findPost(postId);
  const text = p ? `${p.display_name}: ${p.content.slice(0, 80)}` : 'GhostSocial';
  if (navigator.share) {
    try { await navigator.share({ title: 'GhostSocial', text, url }); return; }
    catch(e) { /* отмена пользователем — игнор */ }
  }
  copyPostLink(postId);
}

// ── Профиль: вкладки «Посты» / «Репосты» ─────────────────────────────────────
// scope: 'prof' (свой) или 'fp' (чужой)
async function switchProfTab(scope, tab) {
  const root = scope === 'prof' ? document.getElementById('screenProfile') : document.getElementById('screenFullProfile');
  if (!root) return;
  root.querySelectorAll('.prof-tab').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
  const listId = scope === 'prof' ? 'profList' : 'fpList';
  const list = document.getElementById(listId);
  if (!list) return;
  const uname = scope === 'prof' ? (me && me.username) : (_fpState && _fpState.username);
  if (!uname) return;
  list.innerHTML = skeletonPosts(2);
  if (tab === 'posts') {
    try {
      // Unified timeline (свои посты + репосты в одном списке)
      const items = await api(`/user/${uname}/feed_combined?offset=0&limit=60`);
      if (!items || !items.length) {
        list.innerHTML = '<div class="empty"><i class="fa-regular fa-newspaper"></i><p>Постов пока нет</p></div>';
        return;
      }
      list.innerHTML = renderProfileFeed(items, uname);
      attachEvents(); attachDoubleTap(); loadPreviews(); initAllAudios();
    } catch(e) {
      list.innerHTML = '<div class="empty"><i class="fa-solid fa-triangle-exclamation"></i><p>Ошибка загрузки</p></div>';
    }
  } else if (tab === 'reposts') {
    try {
      const reposts = await api(`/user/${uname}/reposts?offset=0&limit=30`);
      if (!reposts || !reposts.length) {
        list.innerHTML = '<div class="empty"><i class="fa-solid fa-retweet"></i><p>Репостов пока нет</p></div>';
        return;
      }
      list.innerHTML = reposts.map(p => postHTML(p)).join('');
      attachEvents(); attachDoubleTap(); loadPreviews(); initAllAudios();
    } catch(e) {
      list.innerHTML = '<div class="empty"><i class="fa-solid fa-triangle-exclamation"></i><p>Ошибка загрузки</p></div>';
    }
  }
}

// Группируем подряд репосты в мозаики, между ними — свои посты
function renderProfileFeed(items, profileUsername) {
  if (!Array.isArray(items)) {
    console.warn('[renderProfileFeed] items не массив:', items);
    return '';
  }
  const out = [];
  let buf = [];
  const flushMosaic = () => {
    if (!buf.length) return;
    try {
      out.push(renderRepostMosaic(buf, profileUsername));
    } catch(e) {
      console.error('[renderRepostMosaic] упало, fallback на плоский список', e, buf);
      // Fallback — каждый репост как отдельная карточка
      buf.forEach(r => { try { out.push(postHTML(r)); } catch(e2) {} });
    }
    buf = [];
  };
  for (const it of items) {
    if (!it) continue;
    if (it.kind === 'repost') {
      buf.push(it);
    } else {
      flushMosaic();
      try { out.push(postHTML(it)); } catch(e) { console.error('[postHTML]', e, it); }
    }
  }
  flushMosaic();
  return out.join('');
}

// Рендер мозаики: 1 / 2-4 / 5-9 / 10-15 / 16+ (последняя ячейка = "+N ещё")
function renderRepostMosaic(reposts, profileUsername) {
  const n = reposts.length;
  if (n === 1) {
    // Один репост — рендерим как обычный пост с пометкой
    return postHTML(reposts[0]);
  }
  const CAP = 100;
  const items = reposts.slice(0, CAP);
  const overflow = reposts.length > CAP ? reposts.length - CAP : 0;
  // Решаем сколько колонок/ячеек показывать
  let cols;
  let visible;
  if (n <= 4) { cols = 2; visible = n; }
  else if (n <= 9) { cols = 3; visible = n; }
  else if (n <= 16) { cols = 4; visible = n; }
  else { cols = 4; visible = 15; } // 16-я ячейка = "+N"

  const hasMore = (items.length > visible) || overflow > 0;
  const moreCount = (items.length - visible) + overflow;

  const cells = items.slice(0, visible).map(p => {
    const m0 = (p.media && p.media[0]) || null;
    const mediaUrl = m0 ? m0.url : '';
    const mediaType = m0 ? (m0.type || '') : '';
    const isPic = mediaType === 'image' || /\.(jpe?g|png|webp|gif)$/i.test(mediaUrl);
    const isVideo = mediaType === 'video' || /\.(mp4|webm|mov)$/i.test(mediaUrl);
    const isNsfw = !!p.is_nsfw;

    if (isNsfw) {
      // NSFW — превью под сильным блюром (если медиа есть) + бейдж + иконка глаза
      let nsfwMedia = '';
      if (mediaUrl && isPic) {
        nsfwMedia = `<img class="mosaic-img mosaic-blur" src="${mediaUrl}" alt="" onerror="this.classList.add('failed')" loading="lazy">`;
      } else if (mediaUrl && isVideo) {
        nsfwMedia = `<video class="mosaic-video mosaic-blur" src="${mediaUrl}#t=0.1" muted preload="metadata" playsinline onerror="this.classList.add('failed')"></video>`;
      }
      const hasNsfwMedia = !!(mediaUrl && (isPic || isVideo));
      return `<a class="mosaic-cell nsfw${hasNsfwMedia ? ' has-media' : ''}" href="/social/#p=${p.id}" data-post-id="${p.id}" title="@${esc(p.username)}">
        ${nsfwMedia}
        <div class="mosaic-nsfw">18+</div>
        <div class="mosaic-nsfw-center"><i class="fa-solid fa-eye-slash"></i></div>
        <div class="mosaic-author">@${esc(p.username)}</div>
      </a>`;
    }

    // Не-NSFW: используем img/video с onerror-fallback (если файл потерян — серое)
    let mediaLayer = '';
    if (mediaUrl && isPic) {
      mediaLayer = `<img class="mosaic-img" src="${mediaUrl}" alt="" onerror="this.classList.add('failed')" loading="lazy">`;
    } else if (mediaUrl && isVideo) {
      mediaLayer = `<video class="mosaic-video" src="${mediaUrl}#t=0.1" muted preload="metadata" playsinline onerror="this.classList.add('failed')"></video><div class="mosaic-video-icon"><i class="fa-solid fa-play"></i></div>`;
    }
    const hasMedia = !!mediaUrl;
    // Текст показываем только если медиа нет ВООБЩЕ. Если медиа есть — оно само превью.
    const previewText = !hasMedia && p.content ? esc(p.content).slice(0, 60) : '';
    const klass = 'mosaic-cell' + (hasMedia ? ' has-media' : '');
    return `<a class="${klass}" href="/social/#p=${p.id}" data-post-id="${p.id}" title="@${esc(p.username)}: ${esc((p.content||'').slice(0,80))}">
      ${mediaLayer}
      ${previewText ? `<div class="mosaic-text">${previewText}</div>` : ''}
      <div class="mosaic-author">@${esc(p.username)}</div>
    </a>`;
  }).join('');

  const moreCell = hasMore ? `<a class="mosaic-cell mosaic-more" href="javascript:void(0)" onclick="switchProfTab('${profileUsername === me.username ? 'prof' : 'fp'}', 'reposts')">+${moreCount}<br><small>ещё</small></a>` : '';

  return `<div class="post-card repost-mosaic">
    <div class="mosaic-header"><i class="fa-solid fa-retweet"></i> Репостов: ${reposts.length}</div>
    <div class="mosaic-grid" style="grid-template-columns:repeat(${cols},1fr);">
      ${cells}${moreCell}
    </div>
  </div>`;
}

// ── Репосты + Share Sheet (TikTok-style) ─────────────────────────────────────

// Пилюля «кто из подписок репостнул» — ротация аватарок каждые 5 сек
const _repostPillTimers = {};
async function loadRepostPill(postId, el) {
  if (isGuest()) return;
  try {
    const items = await api(`/post/${postId}/reposters/contacts`);
    if (!items || items.length === 0) { el.style.display = 'none'; return; }
    el.style.display = 'inline-flex';
    let idx = 0;
    const render = () => {
      const u = items[idx % items.length];
      el.innerHTML = `<span class="repost-pill-av">${ini(u.display_name || u.username)}</span> <span>@${esc(u.username)} репостнул${items.length > 1 ? ` (+${items.length - 1})` : ''}</span>`;
      el.title = items.map(x => '@' + x.username).join(', ');
      idx++;
    };
    render();
    if (_repostPillTimers[postId]) clearInterval(_repostPillTimers[postId]);
    if (items.length > 1) {
      _repostPillTimers[postId] = setInterval(render, 5000);
    }
  } catch(e) { el.style.display = 'none'; }
}

// Bottom-sheet «Поделиться»
async function openShareSheet(postId) {
  if (document.getElementById('shareSheet')) return;
  const url = buildPostUrl(postId);
  const overlay = document.createElement('div');
  overlay.id = 'shareSheet';
  overlay.style.cssText = 'position:fixed;inset:0;z-index:9998;background:rgba(0,0,0,0.55);backdrop-filter:blur(8px);display:flex;align-items:flex-end;justify-content:center;';
  overlay.innerHTML = `
    <div style="background:#0f172a;border-top-left-radius:18px;border-top-right-radius:18px;width:100%;max-width:520px;padding:14px 14px calc(20px + env(safe-area-inset-bottom));border-top:1px solid rgba(255,255,255,0.08);max-height:80vh;overflow-y:auto;">
      <div style="width:40px;height:4px;background:rgba(255,255,255,0.2);border-radius:99px;margin:0 auto 14px;"></div>
      ${isGuest() ? '<div style="padding:18px;text-align:center;color:var(--sub);">Войдите чтобы делиться</div>' : `
        <input id="shareSearch" placeholder="Найти пользователя..." style="width:100%;padding:10px 14px;background:rgba(15,23,42,0.6);border:1px solid rgba(255,255,255,0.08);border-radius:12px;color:var(--text);font-size:14px;font-family:inherit;outline:none;margin-bottom:12px;">
        <div id="shareContacts" style="display:flex;gap:10px;overflow-x:auto;padding:4px 0 12px;-webkit-overflow-scrolling:touch;"></div>
        <button id="shareSendBtn" style="display:none;width:100%;padding:12px;background:linear-gradient(135deg,var(--primary),var(--primary2));border:none;border-radius:12px;color:#fff;font-size:14px;font-weight:700;cursor:pointer;font-family:inherit;margin-bottom:14px;">Отправить (0)</button>
      `}
      <div style="display:flex;gap:8px;margin-bottom:10px;">
        <button id="repostBtn" style="flex:1;padding:14px;background:rgba(168,85,247,0.10);border:1px solid rgba(168,85,247,0.30);border-radius:12px;color:var(--primary);font-size:14px;font-weight:700;cursor:pointer;font-family:inherit;display:flex;align-items:center;justify-content:center;gap:8px;${isGuest() ? 'opacity:0.5;pointer-events:none;' : ''}">
          <i class="fa-solid fa-retweet"></i> <span id="repostBtnLabel">Репостнуть</span>
        </button>
        <button onclick="copyPostLink(${postId})" style="flex:1;padding:14px;background:rgba(255,255,255,0.05);border:1px solid rgba(255,255,255,0.12);border-radius:12px;color:var(--text);font-size:14px;font-weight:700;cursor:pointer;font-family:inherit;display:flex;align-items:center;justify-content:center;gap:8px;">
          <i class="fa-solid fa-link"></i> Ссылка
        </button>
      </div>
      <div style="display:flex;gap:8px;flex-wrap:wrap;">
        <a href="https://t.me/share/url?url=${encodeURIComponent(url)}" target="_blank" rel="noopener" class="share-ext"><i class="fa-brands fa-telegram"></i> Telegram</a>
        <a href="https://wa.me/?text=${encodeURIComponent(url)}" target="_blank" rel="noopener" class="share-ext"><i class="fa-brands fa-whatsapp"></i> WhatsApp</a>
        <a href="https://twitter.com/intent/tweet?url=${encodeURIComponent(url)}" target="_blank" rel="noopener" class="share-ext"><i class="fa-brands fa-twitter"></i> Twitter</a>
        <button onclick="_copyForDiscord('${url}')" class="share-ext"><i class="fa-brands fa-discord"></i> Discord</button>
      </div>
      <button id="shareCancel" style="display:block;width:100%;margin-top:14px;padding:12px;background:rgba(255,255,255,0.05);border:none;border-radius:12px;color:var(--sub);font-size:14px;font-weight:600;cursor:pointer;font-family:inherit;">Закрыть</button>
    </div>
  `;
  document.body.appendChild(overlay);

  if (!isGuest()) {
    // Загружаем контакты (мои подписки + кому я писал в чате)
    await _loadShareContacts(postId);
    // Поиск
    document.getElementById('shareSearch').addEventListener('input', e => _filterShareContacts(e.target.value));
  }

  // Кнопка репоста — состояние (репостнут уже или нет)
  await _refreshRepostBtn(postId);
  document.getElementById('repostBtn').addEventListener('click', () => _toggleRepost(postId));

  document.getElementById('shareCancel').addEventListener('click', () => overlay.remove());
  overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });
}

function _copyForDiscord(url) {
  navigator.clipboard.writeText(url).then(() => showToast('Ссылка скопирована — вставьте в Discord'));
}

const _shareSelected = new Set();
let _shareAllContacts = [];

async function _loadShareContacts(postId) {
  const box = document.getElementById('shareContacts');
  if (!box) return;
  try {
    // Используем мои подписки как контакт-лист (без отдельного API)
    const d = await api(`/prof/${me.username}`);
    const followingList = await api(`/follows/of/${me.username}/following`).catch(() => []);
    _shareAllContacts = Array.isArray(followingList) ? followingList : [];
    _shareSelected.clear();
    _renderShareContacts(_shareAllContacts);
  } catch(e) {
    box.innerHTML = '<div style="color:var(--sub);font-size:13px;padding:10px;">Нет контактов. Подпишитесь на кого-то.</div>';
  }
}

async function _filterShareContacts(q) {
  q = (q || '').trim().toLowerCase();
  if (!q) {
    _renderShareContacts(_shareAllContacts);
    return;
  }
  // Локальная фильтрация + если ничего не найдено — поиск через /search
  const local = _shareAllContacts.filter(u =>
    (u.username || '').toLowerCase().includes(q) ||
    (u.display_name || '').toLowerCase().includes(q)
  );
  if (local.length > 0) { _renderShareContacts(local); return; }
  // Глобальный поиск
  try {
    const r = await api(`/search?q=${encodeURIComponent(q)}&type=users`);
    _renderShareContacts(r.users || []);
  } catch(e) { _renderShareContacts([]); }
}

function _renderShareContacts(list) {
  const box = document.getElementById('shareContacts');
  if (!box) return;
  if (!list.length) {
    box.innerHTML = '<div style="color:var(--sub);font-size:13px;padding:10px;">Никого не найдено</div>';
    return;
  }
  box.innerHTML = list.map(u => {
    const sel = _shareSelected.has(u.username) ? 'selected' : '';
    return `<button class="share-contact ${sel}" data-user="${esc(u.username)}">
      <div class="share-contact-av">${ini(u.display_name || u.username)}</div>
      <div class="share-contact-name">@${esc(u.username)}</div>
    </button>`;
  }).join('');
  box.querySelectorAll('.share-contact').forEach(btn => {
    btn.addEventListener('click', () => {
      const u = btn.dataset.user;
      if (_shareSelected.has(u)) _shareSelected.delete(u);
      else _shareSelected.add(u);
      btn.classList.toggle('selected');
      _updateSendBtn();
    });
  });
  _updateSendBtn();
}

function _updateSendBtn() {
  const btn = document.getElementById('shareSendBtn');
  if (!btn) return;
  if (_shareSelected.size === 0) { btn.style.display = 'none'; return; }
  btn.style.display = 'block';
  btn.textContent = `Отправить (${_shareSelected.size})`;
  btn.onclick = () => _sendShareToContacts();
}

function _sendShareToContacts() {
  // Получаем post_id из текущего sheet
  const card = document.getElementById('shareSheet');
  if (!card) return;
  const url = buildPostUrl(_currentShareId());
  // Открываем чат с pre-fill для каждого контакта (по очереди — но новой вкладкой)
  const users = Array.from(_shareSelected);
  // Если один — переход в текущей вкладке. Если несколько — открываем новые вкладки
  if (users.length === 1) {
    const u = users[0];
    location.href = `/chat/?to=${encodeURIComponent(u)}&prefill=${encodeURIComponent(url)}`;
    return;
  }
  // Для множественной — копируем ссылку и переход в первого контакта
  navigator.clipboard.writeText(url).then(() => {
    showToast('Ссылка скопирована. Вставь в чаты вручную');
  }).catch(() => {});
  // Открываем чат с первым (юзер сам вставит ссылку остальным)
  setTimeout(() => {
    location.href = `/chat/?to=${encodeURIComponent(users[0])}&prefill=${encodeURIComponent(url)}`;
  }, 800);
}

function _currentShareId() {
  // Из контекста — берём data-post из repostBtn (он есть)
  const btn = document.getElementById('repostBtn');
  if (!btn) return 0;
  return +(btn.dataset.post || _lastShareId || 0);
}

let _lastShareId = 0;
async function _refreshRepostBtn(postId) {
  _lastShareId = postId;
  const btn = document.getElementById('repostBtn');
  if (!btn) return;
  btn.dataset.post = postId;
  // Узнаём — репостил ли я уже? Берём из cached _myReposts (если есть) или из /reposters
  const isReposted = (window._myReposts || new Set()).has(postId);
  document.getElementById('repostBtnLabel').textContent = isReposted ? 'Отменить репост' : 'Репостнуть';
  btn.classList.toggle('reposted', isReposted);
}

window._myReposts = window._myReposts || new Set();

async function _toggleRepost(postId) {
  if (isGuest()) { guestBlock(); return; }
  const isReposted = window._myReposts.has(postId);
  try {
    if (isReposted) {
      await api(`/post/${postId}/repost`, 'DELETE');
      window._myReposts.delete(postId);
      showToast('Репост отменён');
    } else {
      await api(`/post/${postId}/repost`, 'POST');
      window._myReposts.add(postId);
      showToast('Репостнул в свой профиль');
    }
    _refreshRepostBtn(postId);
  } catch(e) { showToast(e.message || 'Ошибка'); }
}

// ── «Сохранить картинкой» — использует серверную OG-PNG ───────────────────────
async function savePostAsImage(postId) {
  const url = `/api/soc/og/post/${postId}.png`;
  // Пробуем скачать в blob и сохранить через <a download>
  try {
    const r = await fetch(url);
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const blob = await r.blob();
    const blobUrl = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = blobUrl;
    a.download = `ghostecos-post-${postId}.png`;
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { document.body.removeChild(a); URL.revokeObjectURL(blobUrl); }, 100);
    showToast('Картинка сохранена');
  } catch(e) {
    // Fallback — открыть в новой вкладке
    window.open(url, '_blank');
  }
}

// ── «Пожаловаться» ──────────────────────────────────────────────────────────
const REPORT_REASONS = [
  { key: 'spam',          icon: 'fa-bullhorn',          label: 'Спам или реклама' },
  { key: 'nsfw_unmarked', icon: 'fa-eye-slash',         label: '18+ без блюра' },
  { key: 'illegal',       icon: 'fa-triangle-exclamation', label: 'Незаконный контент' },
  { key: 'harassment',    icon: 'fa-hand-fist',         label: 'Травля или угрозы' },
  { key: 'other',         icon: 'fa-circle-question',   label: 'Другое' },
];
function openReportSheet(postId) {
  if (isGuest()) { guestBlock(); return; }
  if (document.getElementById('reportSheet')) return;
  const overlay = document.createElement('div');
  overlay.id = 'reportSheet';
  overlay.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.55);backdrop-filter:blur(8px);display:flex;align-items:flex-end;justify-content:center;';
  const opts = REPORT_REASONS.map(r => `
    <button data-reason="${r.key}" style="display:flex;align-items:center;gap:14px;width:100%;padding:14px 16px;background:transparent;border:none;border-radius:12px;color:var(--text);font-size:14px;font-weight:600;cursor:pointer;font-family:inherit;text-align:left;transition:background 0.15s;">
      <i class="fa-solid ${r.icon}" style="color:#f87171;width:18px;text-align:center;"></i>
      ${esc(r.label)}
    </button>
  `).join('');
  overlay.innerHTML = `
    <div style="background:#0f172a;border-top-left-radius:18px;border-top-right-radius:18px;width:100%;max-width:520px;padding:14px 14px calc(20px + env(safe-area-inset-bottom));border-top:1px solid rgba(255,255,255,0.08);">
      <div style="width:40px;height:4px;background:rgba(255,255,255,0.2);border-radius:99px;margin:0 auto 10px;"></div>
      <h3 style="font-size:14px;font-weight:800;text-transform:uppercase;letter-spacing:1px;color:var(--sub);margin:8px 4px 8px;">Причина жалобы</h3>
      <div id="reportOpts" style="display:flex;flex-direction:column;gap:2px;"></div>
      <button id="reportCancel" style="display:block;width:100%;margin-top:10px;padding:12px;background:rgba(255,255,255,0.05);border:none;border-radius:12px;color:var(--sub);font-size:14px;font-weight:600;cursor:pointer;font-family:inherit;">Отмена</button>
    </div>
  `;
  document.body.appendChild(overlay);
  document.getElementById('reportOpts').innerHTML = opts;
  document.getElementById('reportOpts').querySelectorAll('button[data-reason]').forEach(b => {
    b.addEventListener('mouseenter', () => b.style.background = 'rgba(168,85,247,0.08)');
    b.addEventListener('mouseleave', () => b.style.background = 'transparent');
    b.addEventListener('click', async () => {
      const reason = b.dataset.reason;
      overlay.remove();
      try {
        await api(`/post/${postId}/report`, 'POST', { reason });
        showToast('Жалоба отправлена. Модераторы посмотрят.');
      } catch(e) {
        if (e.message && e.message.includes('уже жаловались')) {
          showToast('Вы уже жаловались на этот пост');
        } else {
          showToast(e.message || 'Ошибка');
        }
      }
    });
  });
  document.getElementById('reportCancel').addEventListener('click', () => overlay.remove());
  overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });
}

// ── «Не интересно» и «Скрыть автора» ──────────────────────────────────────────
function hidePostForMe(postId) {
  const p = findPost(postId);
  if (!p) return;
  Algo.onHide(p);
  // Убираем пост из ленты с анимацией
  feedPosts = feedPosts.filter(x => x.id !== postId);
  document.querySelectorAll(`.post-card[data-id="${postId}"]`).forEach(el => {
    el.style.transition = 'opacity 0.3s, transform 0.3s, max-height 0.4s';
    el.style.opacity = '0';
    el.style.transform = 'translateX(-30px)';
    el.style.maxHeight = '0';
    el.style.overflow = 'hidden';
    setTimeout(() => el.remove(), 400);
  });
  showToast('Скрыто. Реже буду показывать похожее.');
}

function blockAuthor(username) {
  showConfirm({
    title: `Скрыть @${username}?`,
    msg: 'Посты этого автора больше не будут показываться в твоей ленте «Для вас». Можно отменить в настройках алгоритма.',
    okText: 'Скрыть',
    danger: true,
    onOk: () => {
      Algo.onBlockAuthor(username);
      // Убрать все его посты из текущей ленты
      const removed = [];
      feedPosts = feedPosts.filter(p => { if (p.username === username) { removed.push(p.id); return false; } return true; });
      removed.forEach(id => {
        document.querySelectorAll(`.post-card[data-id="${id}"]`).forEach(el => {
          el.style.transition = 'opacity 0.3s';
          el.style.opacity = '0';
          setTimeout(() => el.remove(), 300);
        });
      });
      showToast(`@${username} скрыт`);
    },
  });
}

// ── Emoji palette ──────────────────────────────────────────────────────────────

let _emojiOpenFor = null;

function openEmojiPalette(triggerBtn) {
  closeEmojiPalette();
  const wrap = triggerBtn.closest('.react-trigger');
  if (!wrap) return;
  const pid = +wrap.dataset.post;
  const p = findPost(pid);
  const cur = p && p.reactions && p.reactions.your_emoji;
  const bar = document.createElement('div');
  bar.className = 'emoji-bar';
  bar.innerHTML = EMOJI_ORDER.map(k =>
    `<button class="emoji-btn${k === cur ? ' active' : ''}" data-emoji="${k}" title="${esc(EMOJI[k].label)}">${emojiSvg(k)}</button>`
  ).join('');
  wrap.appendChild(bar);
  requestAnimationFrame(() => bar.classList.add('open'));
  bar.querySelectorAll('.emoji-btn').forEach(b => {
    b.addEventListener('click', e => {
      e.stopPropagation();
      const em = b.dataset.emoji;
      sendReaction(pid, em === cur ? null : em);
      closeEmojiPalette();
    });
  });
  _emojiOpenFor = bar;
}

function closeEmojiPalette() {
  if (_emojiOpenFor) {
    _emojiOpenFor.remove();
    _emojiOpenFor = null;
  }
}

// ── Tag feed ───────────────────────────────────────────────────────────────────

let currentTag = null;
function openTag(tag) {
  Algo.onTagClick(tag);
  currentTag = tag;
  switchScreen('screenFeed');
  document.getElementById('feedContext').innerHTML = `
    <div class="feed-context">
      <div class="feed-context-text">Лента по тегу <b>#${esc(tag)}</b></div>
      <button class="feed-context-close" onclick="closeTag()" title="Закрыть"><i class="fa-solid fa-xmark"></i></button>
    </div>`;
  resetFeed(); loadFeed(); scrollTo(0, 0);
}

function closeTag() {
  currentTag = null;
  document.getElementById('feedContext').innerHTML = '';
  resetFeed(); loadFeed();
}

// ── Comments ───────────────────────────────────────────────────────────────────

async function openComments(postId) {
  curCommentPostId = postId; commentOffset = 0;
  document.getElementById('commentsList').innerHTML = '<div style="text-align:center;padding:20px"><div class="spinner spinner-sm" style="margin:0 auto"></div></div>';
  document.getElementById('commentsMore').innerHTML = '';
  document.getElementById('commentInput').value = '';
  document.getElementById('commentsModal').classList.add('open');
  await loadComments(false);
}
async function loadComments(append = false) {
  try {
    const r = await api(`/com/get/${curCommentPostId}?offset=${commentOffset}`);
    commentOffset += r.comments.length;
    const list = document.getElementById('commentsList');
    if (!append) { list.innerHTML = r.comments.length ? r.comments.map(commentHTML).join('') : '<div class="no-more">Комментариев пока нет</div>'; }
    else if (r.comments.length) list.innerHTML += r.comments.map(commentHTML).join('');
    const more = document.getElementById('commentsMore');
    if (r.has_more) more.innerHTML = '<button class="load-more-btn" onclick="loadComments(true)">Загрузить ещё</button>';
    else if (commentOffset > 0) more.innerHTML = '<div class="no-more">Комментариев больше нет</div>';
    else more.innerHTML = '';
  } catch(e) {}
}
function commentHTML(c) {
  const post = findPost(curCommentPostId);
  const canDelete = me && (c.username === me.username || (post && post.user_id === me.id));
  return `<div class="comment-item" data-cid="${c.id}">
    <div class="comment-item-row">
      <div class="comment-item-body">
        <div class="comment-author">
          <a class="mention" href="#u=${encodeURIComponent(c.username)}" onclick="event.preventDefault();closeModal('commentsModal');openFullProfile(${jsAttr(c.username)})">@${esc(c.username)}</a>
          <span style="color:#334155;font-weight:400">${esc(c.display_name)}</span>
        </div>
        <div class="comment-text">${linkifyContent(c.text)}</div>
        <div class="comment-time">${ago(c.created_at)}</div>
      </div>
      ${canDelete ? `<button class="comment-del" onclick="deleteComment(${c.id})" title="Удалить"><i class="fa-solid fa-trash-can"></i></button>` : ''}
    </div>
  </div>`;
}

async function deleteComment(cid) {
  showConfirm({
    title: 'Удалить комментарий?',
    msg: 'Это действие нельзя отменить.',
    okText: 'Удалить',
    danger: true,
    onOk: async () => {
      try {
        await api(`/com/${cid}`, 'DELETE');
        const el = document.querySelector(`.comment-item[data-cid="${cid}"]`);
        if (el) { el.style.opacity = '0'; el.style.transition = 'opacity 0.25s'; setTimeout(() => el.remove(), 250); }
        // обновим счётчик коммента в посте
        const p = findPost(curCommentPostId);
        if (p && p.comments_count > 0) {
          p.comments_count--;
          const cc = document.querySelector(`[data-post="${curCommentPostId}"][data-action="comment"] .cc`);
          if (cc) cc.textContent = p.comments_count;
        }
      } catch(e) { showToast('Ошибка удаления'); }
    }
  });
}
document.getElementById('commentSend').addEventListener('click', async () => {
  if (isGuest()) { guestBlock(); return; }
  const inp = document.getElementById('commentInput');
  const text = inp.value.trim();
  if (!text || !curCommentPostId) return;
  try {
    await api(`/com/${curCommentPostId}`, 'POST', { text });
    const _p = findPost(curCommentPostId);
    if (_p) Algo.onComment(_p);
    inp.value = ''; commentOffset = 0;
    await loadComments(false);
    refreshWallet();  // +2 автору поста (если это не я — WS прилетит ему; если я — ничего)
    const p = feedPosts.find(x => x.id === curCommentPostId);
    if (p) { p.comments_count++; const el = document.querySelector(`[data-post="${curCommentPostId}"][data-action="comment"] .cc`); if (el) el.textContent = p.comments_count; }
    // Миниска тоже может содержать этот пост — обновим счётчик там
    const msk = _mskItems && _mskItems.find(x => x.id === curCommentPostId);
    if (msk) {
      msk.comments_count = (msk.comments_count || 0) + 1;
      const card = document.querySelector(`.msk-card[data-id="${curCommentPostId}"]`);
      if (card) {
        const lbl = card.querySelectorAll('.msk-side .lbl')[1];
        if (lbl) lbl.textContent = msk.comments_count;
      }
    }
  } catch(e) { showToast('Ошибка отправки'); }
});
document.getElementById('commentInput').addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); document.getElementById('commentSend').click(); }
});

// ── Profiles ───────────────────────────────────────────────────────────────────

async function openMini(username) { openFullProfile(username); }

let fullProfPrevScreen = 'screenFeed';
let _fpState = { username: null, offset: 0, hasMore: true, loading: false };
window._profPosts = [];

async function openFullProfile(username) {
  if (me && username !== me.username) Algo.onOpenProfile(username);
  const active = document.querySelector('.screen.active');
  const activeId = active ? active.id : 'screenFeed';
  if (activeId !== 'screenFullProfile') fullProfPrevScreen = activeId;
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById('screenFullProfile').classList.add('active');
  document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));
  stopNewCheck();
  _fpState = { username, offset: 0, hasMore: true, loading: false };
  window._profPosts = [];
  document.getElementById('fpAv').textContent = '?';
  document.getElementById('fpName').textContent = '...';
  document.getElementById('fpUser').textContent = '@' + username;
  document.getElementById('fpPosts').textContent = '—';
  document.getElementById('fpFollowers').textContent = '—';
  document.getElementById('fpFollowing').textContent = '—';
  document.getElementById('fpReceived').textContent = '—';
  document.getElementById('fpFollowWrap').style.display = 'none';
  document.getElementById('fpMessageWrap').style.display = 'none';
  document.getElementById('fpList').innerHTML = skeletonPosts(2);
  try {
    const d = await api(`/prof/${username}`);
    document.getElementById('fpAv').textContent = ini(d.display_name);
    document.getElementById('fpName').textContent = d.display_name;
    document.getElementById('fpUser').textContent = '@' + d.username;
    renderDailyStatus('fpStatus', d.daily_status);
    renderReputation('fpReputation', d.reputation_score, d.reputation_band);
    const wb = document.getElementById('fpWrappedBtn');
    if (wb) wb.href = buildWrappedUrl(d.username);
    document.getElementById('fpPosts').textContent = d.posts_count;
    document.getElementById('fpFollowers').textContent = d.followers_count;
    document.getElementById('fpFollowing').textContent = d.following_count;
    document.getElementById('fpReceived').textContent = d.likes_received;
    if (!d.is_me) {
      document.getElementById('fpFollowWrap').style.display = 'block';
      renderFollowBtn('fpFollowBtn', d.username, d.am_following);
      // Кнопка «Написать» — только не гостям и не себе
      if (!isGuest()) {
        document.getElementById('fpMessageWrap').style.display = 'block';
        document.getElementById('fpMessageBtn').href = `/chat/?to=${encodeURIComponent(d.username)}&from=${encodeURIComponent(location.pathname + location.search)}`;
      }
    } else {
      document.getElementById('fpMessageWrap').style.display = 'none';
    }
    window._profPosts = d.posts;
    _fpState.offset = d.posts.length;
    if (d.posts.length < 15) _fpState.hasMore = false;
    // Используем feed_combined чтобы показать мозаики репостов
    try {
      const items = await api(`/user/${d.username}/feed_combined?limit=60`);
      window._profPosts = items.filter(x => x.kind === 'self');
      document.getElementById('fpList').innerHTML = items.length
        ? renderProfileFeed(items, d.username) + '<div id="fpLoader" style="text-align:center;padding:16px;display:none"><div class="spinner spinner-sm" style="margin:0 auto"></div></div>'
        : '<div class="empty"><i class="fa-regular fa-newspaper"></i><p>Постов пока нет</p></div>';
    } catch(e2) {
      document.getElementById('fpList').innerHTML = d.posts.length
        ? d.posts.map(p => postHTML(p)).join('') + '<div id="fpLoader" style="text-align:center;padding:16px;display:none"><div class="spinner spinner-sm" style="margin:0 auto"></div></div>'
        : '<div class="empty"><i class="fa-regular fa-newspaper"></i><p>Постов пока нет</p></div>';
    }
    attachEvents(); attachDoubleTap(); loadPreviews(); initAllAudios();
  } catch(e) {
    document.getElementById('fpList').innerHTML = '<div class="empty"><i class="fa-solid fa-triangle-exclamation"></i><p>Ошибка загрузки</p></div>';
  }
}

async function loadFpMore() {
  if (_fpState.loading || !_fpState.hasMore || !_fpState.username) return;
  _fpState.loading = true;
  const loader = document.getElementById('fpLoader');
  if (loader) loader.style.display = 'block';
  try {
    const more = await api(`/prof/${_fpState.username}/posts?offset=${_fpState.offset}`);
    _fpState.offset += more.length;
    if (more.length < 15) _fpState.hasMore = false;
    window._profPosts.push(...more);
    if (more.length) {
      const html = more.map(p => postHTML(p)).join('');
      if (loader) loader.insertAdjacentHTML('beforebegin', html);
      attachEvents(); attachDoubleTap(); loadPreviews(); initAllAudios();
    }
  } catch(e) {}
  if (loader) loader.style.display = 'none';
  _fpState.loading = false;
}

function renderFollowBtn(btnId, username, following) {
  const btn = document.getElementById(btnId);
  if (!btn) return;
  btn.classList.toggle('following', !!following);
  btn.innerHTML = following
    ? `<i class="fa-solid fa-check"></i><span class="follow-label"><span class="follow-label-text">Вы подписаны</span></span>`
    : `<i class="fa-solid fa-user-plus"></i><span>Подписаться</span>`;
  btn.onclick = async () => {
    if (isGuest()) { guestBlock(); return; }
    btn.disabled = true;
    try {
      if (following) {
        await api(`/follow/${username}`, 'DELETE');
        Algo.onFollow(username, false);
        renderFollowBtn(btnId, username, false);
        const fc = document.getElementById('fpFollowers');
        if (fc) fc.textContent = Math.max(0, (+fc.textContent || 1) - 1);
        // В ленте — вернуть кнопки «Подписаться» на постах этого автора
        feedPosts.forEach(p => { if (p.username === username) p.am_following = false; });
      } else {
        await api(`/follow/${username}`, 'POST');
        Algo.onFollow(username, true);
        renderFollowBtn(btnId, username, true);
        refreshWallet();
        const fc = document.getElementById('fpFollowers');
        if (fc) fc.textContent = (+fc.textContent || 0) + 1;
        // В ленте — убрать кнопки «Подписаться» с постов этого автора
        feedPosts.forEach(p => { if (p.username === username) p.am_following = true; });
        document.querySelectorAll(`[data-action="post-follow"][data-username="${username}"]`).forEach(b => b.remove());
      }
    } catch(e) { showToast('Ошибка'); }
    btn.disabled = false;
  };
}

// ── Шеринг профиля ────────────────────────────────────────────────────────────
async function _shareUrl(url, title, text) {
  if (navigator.share) {
    try { await navigator.share({ url, title, text }); return; }
    catch(e) { /* отмена пользователем — игнор */ }
  }
  try {
    await navigator.clipboard.writeText(url);
    showToast('Ссылка скопирована');
  } catch(e) {
    const ta = document.createElement('textarea');
    ta.value = url; document.body.appendChild(ta); ta.select();
    try { document.execCommand('copy'); showToast('Ссылка скопирована'); }
    catch(e2) { showToast(url); }
    finally { document.body.removeChild(ta); }
  }
}
function shareMyProfile() {
  if (!me) return;
  _shareUrl(buildUserUrl(me.username), `@${me.username}`, `Профиль ${me.display_name || me.username} в GhostEcos`);
}
function shareForeignProfile() {
  const un = _fpState && _fpState.username;
  if (!un) return;
  _shareUrl(buildUserUrl(un), `@${un}`, `Профиль @${un} в GhostEcos`);
}

// 1500 → 1.5K, 1_200_000 → 1.2M (компактно для UI-счётчиков)
function formatCount(n) {
  n = +n || 0;
  if (n < 1000) return String(n);
  if (n < 1000000) return (n / 1000).toFixed(n < 10000 ? 1 : 0).replace(/\.0$/, '') + 'K';
  return (n / 1000000).toFixed(1).replace(/\.0$/, '') + 'M';
}

function renderDailyStatus(elId, text) {
  const el = document.getElementById(elId);
  if (!el) return;
  if (!text || !text.trim()) { el.style.display = 'none'; return; }
  el.style.display = 'block';
  el.textContent = text;
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

async function loadMyProfile() {
  if (!me) return;
  document.getElementById('profList').innerHTML = skeletonPosts(2);
  try {
    const d = await api(`/prof/${me.username}`);
    document.getElementById('profAv').textContent = ini(d.display_name);
    document.getElementById('profName').textContent = d.display_name;
    document.getElementById('profUser').textContent = '@' + d.username;
    renderDailyStatus('profStatus', d.daily_status);
    renderReputation('profReputation', d.reputation_score, d.reputation_band);
    document.getElementById('sPosts').textContent = d.posts_count;
    document.getElementById('sFollowers').textContent = d.followers_count;
    document.getElementById('sFollowing').textContent = d.following_count;
    document.getElementById('sReceived').textContent = d.likes_received;
    window._profPosts = d.posts;  // чтобы findPost нашёл их при клике на реакцию/коммент
    // Используем feed_combined чтобы показать мозаики репостов в вкладке «Посты»
    try {
      const items = await api(`/user/${me.username}/feed_combined?limit=60`);
      window._profPosts = items.filter(x => x.kind === 'self');  // для findPost
      document.getElementById('profList').innerHTML = items.length
        ? renderProfileFeed(items, me.username)
        : '<div class="empty"><i class="fa-regular fa-newspaper"></i><p>Постов пока нет</p></div>';
    } catch(e2) {
      // fallback на старый /prof
      document.getElementById('profList').innerHTML = d.posts.length ? d.posts.map(p => postHTML(p)).join('') : '<div class="empty"><i class="fa-regular fa-newspaper"></i><p>Постов пока нет</p></div>';
    }
    attachEvents(); attachDoubleTap(); loadPreviews(); initAllAudios();
  } catch(e) {}
}

document.getElementById('fullProfBack').addEventListener('click', () => {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById(fullProfPrevScreen).classList.add('active');
  const screenToNav = { screenFeed: 'navFeed', screenSearch: 'navSearch', screenCreate: 'navCreate', screenProfile: 'navProfile' };
  const navId = screenToNav[fullProfPrevScreen];
  if (navId) document.getElementById(navId).classList.add('active');
  if (fullProfPrevScreen === 'screenFeed') startNewCheck();
});

// ── Edit profile ───────────────────────────────────────────────────────────────

function openEditProfile() {
  document.getElementById('editDisplayName').value = me ? (me.display_name || '') : '';
  document.getElementById('editUsername').value = me ? (me.username || '') : '';
  document.getElementById('editNewPassword').value = '';
  document.getElementById('editConfirmPassword').value = '';
  document.getElementById('editOldPassword').value = '';
  document.getElementById('editOldPwdWrap').style.display = 'none';
  document.getElementById('editProfileErr').textContent = '';
  document.getElementById('editProfileModal').classList.add('open');
  setTimeout(() => document.getElementById('editDisplayName').focus(), 300);
}

function _editNeedsOldPwd() {
  const usernameChanged = document.getElementById('editUsername').value.trim() !== (me?.username || '');
  const hasNewPwd = document.getElementById('editNewPassword').value.length > 0;
  return usernameChanged || hasNewPwd;
}

['editUsername', 'editNewPassword'].forEach(id => {
  document.getElementById(id).addEventListener('input', () => {
    document.getElementById('editOldPwdWrap').style.display = _editNeedsOldPwd() ? 'block' : 'none';
  });
});

document.getElementById('editProfileBtn').addEventListener('click', async () => {
  const btn = document.getElementById('editProfileBtn');
  const errEl = document.getElementById('editProfileErr');
  errEl.textContent = '';

  const display_name = document.getElementById('editDisplayName').value.trim();
  const username = document.getElementById('editUsername').value.trim();
  const new_password = document.getElementById('editNewPassword').value;
  const confirm = document.getElementById('editConfirmPassword').value;
  const old_password = document.getElementById('editOldPassword').value;

  // Client-side checks
  if (new_password && new_password !== confirm) { errEl.textContent = 'Пароли не совпадают'; return; }
  if (new_password && new_password.length < 8) { errEl.textContent = 'Пароль слишком короткий (минимум 8 символов)'; return; }

  const body = {};
  if (display_name && display_name !== me?.display_name) body.display_name = display_name;
  if (username && username !== me?.username) body.username = username;
  if (new_password) body.new_password = new_password;
  if (old_password) body.old_password = old_password;

  if (!Object.keys(body).length) { closeModal('editProfileModal'); return; }

  btn.disabled = true; btn.textContent = '...';
  try {
    const r = await api('/me', 'PATCH', body);
    me.display_name = r.display_name;
    me.username = r.username;
    localStorage.setItem('gs_me', JSON.stringify(me));
    document.getElementById('hAvatar').textContent = ini(me.display_name);
    closeModal('editProfileModal');
    showToast('Профиль обновлён');
    loadMyProfile();
  } catch(e) {
    errEl.textContent = e.message || 'Ошибка сохранения';
  }
  btn.disabled = false; btn.textContent = 'Сохранить';
});

// ── Search ─────────────────────────────────────────────────────────────────────

let searchTimeout = null, searchSeq = 0;
const searchInput = document.getElementById('searchInput');
const searchClear = document.getElementById('searchClear');

searchInput.addEventListener('input', () => {
  const q = searchInput.value;
  searchClear.classList.toggle('show', q.length > 0);
  clearTimeout(searchTimeout);
  if (!q.trim()) { searchSeq++; document.getElementById('searchResults').innerHTML = ''; return; }
  searchTimeout = setTimeout(() => doSearch(q), 300);
});
searchInput.addEventListener('keydown', e => {
  if (e.key === 'Enter') { e.preventDefault(); clearTimeout(searchTimeout); const q = searchInput.value.trim(); if (q) doSearch(q); }
});
searchClear.addEventListener('click', () => {
  searchInput.value = ''; searchClear.classList.remove('show');
  document.getElementById('searchResults').innerHTML = '';
});

async function doSearch(q) {
  const seq = ++searchSeq;
  const hlQuery = q.startsWith('@') ? q.slice(1) : q;
  const res = document.getElementById('searchResults');
  res.innerHTML = '<div style="text-align:center;padding:20px"><div class="spinner spinner-sm" style="margin:0 auto"></div></div>';
  try {
    const d = await api(`/search?q=${encodeURIComponent(q)}`);
    if (seq !== searchSeq) return;
    if (d.type === 'users') {
      if (!d.results.length) { res.innerHTML = '<div class="empty"><i class="fa-solid fa-user-slash"></i><p>Пользователи не найдены</p></div>'; return; }
      res.innerHTML = d.results.map(u => `
        <div class="user-card" onclick="openFullProfile(${jsAttr(u.username)})">
          <div class="user-card-av">${ini(u.display_name)}</div>
          <div class="user-card-info">
            <div class="user-card-name">${highlightText(u.display_name, hlQuery)}</div>
            <div class="user-card-user">@${highlightText(u.username, hlQuery)}</div>
          </div>
          <div class="user-card-posts">${u.posts_count} постов</div>
        </div>
      `).join('');
    } else {
      if (!d.results.length) { res.innerHTML = '<div class="empty"><i class="fa-regular fa-newspaper"></i><p>Постов не найдено</p></div>'; return; }
      res.innerHTML = d.results.map(p => postHTML(p, hlQuery)).join('');
      attachEvents(); attachDoubleTap(); loadPreviews(); initAllAudios();
    }
  } catch(e) {
    if (seq !== searchSeq) return;
    res.innerHTML = '<div class="empty"><i class="fa-solid fa-triangle-exclamation"></i><p>Ошибка поиска</p></div>';
  }
}

// ── Auto-update counts ─────────────────────────────────────────────────────────

let countsInterval = null;
function startCountsUpdate() { stopCountsUpdate(); countsInterval = setInterval(updateCounts, 10000); }
function stopCountsUpdate() { if (countsInterval) { clearInterval(countsInterval); countsInterval = null; } }

async function updateCounts() {
  const visible = feedPosts.slice(renderStart);
  if (!visible.length) return;
  const ids = visible.map(p => p.id).join(',');
  try {
    const data = await api(`/post/counts?ids=${ids}`);
    visible.forEach(p => {
      const u = data[p.id]; if (!u) return;
      const r = u.reactions || { counts: {}, your_emoji: null, total: 0 };
      const changed = JSON.stringify(p.reactions) !== JSON.stringify(r)
                   || p.comments_count !== u.comments_count;
      if (!changed) return;
      p.reactions = r;
      p.comments_count = u.comments_count;
      document.querySelectorAll(`.post-card[data-id="${p.id}"]`).forEach(card => {
        const row = card.querySelector('[data-action="reactions-row"]');
        const tog = card.querySelector('[data-action="react-toggle"]');
        const cc = card.querySelector(`[data-action="comment"] .cc`);
        if (row) row.innerHTML = reactionsHTML(p);
        if (tog) {
          tog.classList.toggle('liked', !!r.your_emoji);
          tog.querySelector('i').className = `fa-${r.your_emoji ? 'solid' : 'regular'} fa-heart`;
        }
        if (cc) cc.textContent = u.comments_count;
      });
    });
    attachEvents(); attachDoubleTap(); loadPreviews(); initAllAudios();
  } catch(e) {}
}

init();

// ══════════════════════════════════════════════════════════════════════════════
// MODERATION SCREEN
// ══════════════════════════════════════════════════════════════════════════════
function openModerationOrAdmin() {
  // Admin → отдельная админка. Модератор/юзер → старый экран в социалке.
  if (me && me.is_admin) {
    location.href = '/social/admin';
    return;
  }
  switchScreen('screenModeration');
}

async function loadModerationScreen() {
  const root = document.getElementById('modContent');
  const badge = document.getElementById('modBadge');
  root.innerHTML = '<div style="text-align:center;color:var(--sub);padding:30px;">Загрузка...</div>';
  let me_mod;
  try { me_mod = await api('/mod/me'); }
  catch(e) { root.innerHTML = `<div style="color:var(--red);padding:20px;">Ошибка: ${esc(e.message||'')}</div>`; return; }

  badge.textContent = me_mod.is_admin ? 'Owner' : (me_mod.is_moderator ? 'Модератор' : 'Юзер');

  let html = '';

  // Status card
  html += `<div style="padding:14px;background:rgba(168,85,247,0.05);border:1px solid rgba(168,85,247,0.20);border-radius:14px;">
    <div style="font-size:13px;color:var(--sub);margin-bottom:8px;">Твой статус</div>
    <div style="font-size:15px;font-weight:600;">
      ${me_mod.is_admin ? 'Owner экосистемы' : me_mod.is_moderator ? 'Модератор' : 'Обычный юзер'}
    </div>
    ${me_mod.is_moderator ? `
      <div style="margin-top:8px;font-size:12px;color:var(--sub);">
        Рейтинг: <b style="color:var(--text);">${me_mod.rating}</b> ·
        Выговоров: <b style="color:var(--text);">${me_mod.reprimands}/3</b> ·
        Проверок: <b style="color:var(--text);">${me_mod.votes_count}</b>
      </div>
    ` : ''}
  </div>`;

  // For non-moderators: button to apply
  if (!me_mod.is_moderator && !me_mod.is_admin) {
    html += `<div style="padding:14px;background:var(--surface);border:1px solid var(--border);border-radius:14px;">
      <div style="font-weight:600;margin-bottom:8px;">Стать модератором</div>
      <div style="font-size:12px;color:var(--sub);line-height:1.5;margin-bottom:12px;">
        Подача заявки стоит <b>200 Gost</b>. Заявку рассматривает владелец экосистемы.
        Модераторы проверяют посты на overwatch и получают Gost за голоса.
      </div>
      <button onclick="applyForModerator()" style="width:100%;padding:11px;border-radius:10px;border:none;background:linear-gradient(135deg,var(--primary),var(--primary2));color:#fff;font-weight:700;cursor:pointer;font-family:inherit;font-size:13px;">
        Подать заявку (200 Gost)
      </button>
    </div>`;
  }

  // Admin view: search + current mods + applications
  if (me_mod.is_admin) {
    // Поиск и прямое назначение
    html += `<div style="padding:14px;background:var(--surface);border:1px solid var(--border);border-radius:14px;">
      <div style="font-weight:600;margin-bottom:10px;">Назначить модератором напрямую</div>
      <div style="display:flex;gap:6px;margin-bottom:8px;">
        <input id="modSearchInp" placeholder="@username или имя"
          style="flex:1;padding:10px 12px;border-radius:8px;border:1px solid var(--border-strong);background:rgba(0,0,0,0.25);color:var(--text);font-family:inherit;font-size:13px;"
          oninput="modSearchUsers(this.value)">
      </div>
      <div id="modSearchResults" style="display:flex;flex-direction:column;gap:6px;"></div>
    </div>`;

    // Текущие модераторы (для снятия)
    let mods = [];
    try { mods = await api('/mod/list'); } catch(_) {}
    if (mods.length) {
      html += `<div style="padding:14px;background:var(--surface);border:1px solid var(--border);border-radius:14px;">
        <div style="font-weight:600;margin-bottom:10px;">Текущие модераторы (${mods.length})</div>
        <div style="display:flex;flex-direction:column;gap:6px;">
          ${mods.map(m => modListCard(m)).join('')}
        </div>
      </div>`;
    }

    // Заявки
    let apps = [];
    try { apps = await api('/mod/applications'); } catch(_) {}
    html += `<div style="padding:14px;background:var(--surface);border:1px solid var(--border);border-radius:14px;">
      <div style="font-weight:600;margin-bottom:10px;">Заявки в модераторы (${apps.filter(a=>a.status==='pending').length} pending)</div>
      ${apps.length ? apps.map(a => modAppCard(a)).join('') : '<div style="color:var(--sub);font-size:13px;text-align:center;padding:14px;">Заявок нет</div>'}
    </div>`;
  }

  // Moderator view: overwatch queue
  if (me_mod.is_moderator || me_mod.is_admin) {
    let queue = [];
    try { queue = await api('/mod/overwatch_queue'); } catch(_) {}
    html += `<div style="padding:14px;background:var(--surface);border:1px solid var(--border);border-radius:14px;">
      <div style="font-weight:600;margin-bottom:10px;">Очередь overwatch (${queue.length})</div>
      <div style="font-size:11px;color:var(--sub);margin-bottom:12px;line-height:1.5;">
        Только контент. Автор скрыт. Жалоба за раскрытие личности — штраф 1000 Gost.
      </div>
      ${queue.length ? queue.map(ow => owCard(ow)).join('') : '<div style="color:var(--sub);font-size:13px;text-align:center;padding:14px;">Постов на проверку нет</div>'}
    </div>`;
  }

  root.innerHTML = html;
}

function modAppCard(a) {
  const isPending = a.status === 'pending';
  const ago = Math.round((Date.now()/1000 - a.created_at) / 3600);
  const userArg = jsAttr(a.username);
  return `<div style="padding:12px;background:rgba(0,0,0,0.20);border-radius:10px;margin-bottom:8px;border-left:3px solid ${isPending ? 'var(--primary)' : a.status==='accepted' ? '#22c55e' : 'var(--red)'};">
    <div style="display:flex;align-items:center;gap:8px;margin-bottom:6px;cursor:pointer;" onclick="openFullProfile(${userArg})" title="Открыть профиль">
      <div style="width:30px;height:30px;border-radius:50%;background:linear-gradient(135deg,var(--primary),var(--primary2));display:flex;align-items:center;justify-content:center;color:#fff;font-size:12px;font-weight:700;">${(a.display_name||a.username||'?')[0].toUpperCase()}</div>
      <div style="flex:1;">
        <div style="font-weight:600;font-size:13px;">${esc(a.display_name||a.username)}</div>
        <div style="font-size:11px;color:var(--sub);">@${esc(a.username)} · ${ago}ч назад</div>
      </div>
      <div style="font-size:11px;padding:3px 8px;border-radius:6px;background:rgba(255,255,255,0.05);color:var(--text);font-weight:700;">
        ${a.quality_score}/100
      </div>
    </div>
    <div style="font-size:11px;color:var(--sub);margin-bottom:8px;">
      Постов: <b style="color:var(--text);">${a.posts_count}</b> ·
      Комментов: <b style="color:var(--text);">${a.comments_count}</b> ·
      Gost: <b style="color:var(--text);">${a.gost_balance ?? 0}</b>
    </div>
    ${isPending ? `<div style="display:flex;gap:6px;">
      <button onclick="modDecide(${a.id}, true)" style="flex:1;padding:8px;border-radius:8px;border:none;background:#22c55e;color:#fff;font-weight:600;cursor:pointer;font-family:inherit;font-size:12px;">Принять</button>
      <button onclick="modDecide(${a.id}, false)" style="flex:1;padding:8px;border-radius:8px;border:1px solid rgba(244,63,94,0.4);background:transparent;color:var(--red);font-weight:600;cursor:pointer;font-family:inherit;font-size:12px;">Отклонить</button>
    </div>` : `<div style="font-size:11px;color:var(--sub);font-style:italic;">${a.status === 'accepted' ? 'Принят' : 'Отклонён'}</div>`}
  </div>`;
}

function owCard(ow) {
  const myVote = ow.my_vote;
  const voted = myVote != null;
  return `<div style="padding:12px;background:rgba(0,0,0,0.20);border-radius:10px;margin-bottom:8px;border-left:3px solid var(--primary);">
    <div style="display:flex;align-items:center;gap:8px;margin-bottom:6px;font-size:11px;color:var(--sub);">
      <span>activity: <b style="color:var(--text);">${ow.current_activity}/1000</b></span>
      <span>·</span>
      <span>${ow.kind === 'manual' ? '💵 Платный' : '⚡ Системный'}</span>
    </div>
    <div style="background:rgba(0,0,0,0.30);padding:10px;border-radius:8px;font-size:13px;line-height:1.55;margin-bottom:10px;">
      ${esc(ow.content || '(пусто)')}
    </div>
    ${voted ? `<div style="font-size:12px;color:var(--sub);">Ты проголосовал: <b>${myVote > 0 ? '+' : ''}${myVote}</b></div>`
      : `<div style="display:flex;gap:4px;flex-wrap:wrap;">
        ${[-150, -50, 0, 50, 150].map(d =>
          `<button onclick="owVote(${ow.request_id}, ${d})" style="flex:1;padding:8px;border-radius:8px;border:1px solid ${d < 0 ? 'rgba(244,63,94,0.4)' : d > 0 ? 'rgba(34,197,94,0.4)' : 'var(--border-strong)'};background:transparent;color:${d < 0 ? 'var(--red)' : d > 0 ? '#22c55e' : 'var(--text)'};font-weight:600;cursor:pointer;font-family:inherit;font-size:12px;min-width:50px;">
            ${d > 0 ? '+' : ''}${d}
          </button>`
        ).join('')}
      </div>`}
  </div>`;
}

// ── Видимость поста + покупка overwatch ──
async function openPostActivity(postId) {
  let data;
  try { data = await api(`/post/${postId}/activity`); }
  catch(e) { return showToast(e.message || 'Ошибка'); }
  const a = data.activity;
  const level = a >= 700 ? 'Высокая' : a >= 300 ? 'Средняя' : a >= 100 ? 'Низкая' : 'Скрыт';
  const colour = a >= 700 ? '#22c55e' : a >= 300 ? 'var(--primary)' : a >= 100 ? '#fbbf24' : 'var(--red)';
  const setSrc = { 'B': 'История юзера', 'overwatch': 'Решение модераторов', 'system': 'Авто-система', 'manual': 'Ручная' }[data.automod_source] || data.automod_source || '—';
  const histHtml = data.history && data.history.length ? data.history.map(h => `
    <div style="display:flex;gap:8px;padding:6px 0;border-bottom:1px solid var(--border);font-size:11px;">
      <span style="color:var(--muted);width:60px;">${new Date(h.created_at*1000).toLocaleDateString('ru')}</span>
      <span style="color:${h.delta > 0 ? '#22c55e' : h.delta < 0 ? 'var(--red)' : 'var(--sub)'};font-weight:700;width:50px;">${h.delta > 0 ? '+' : ''}${h.delta}</span>
      <span style="color:var(--sub);flex:1;">${esc(h.source)}${h.note ? ' · ' + esc(h.note) : ''}</span>
    </div>
  `).join('') : '<div style="font-size:11px;color:var(--muted);text-align:center;padding:8px;">История пуста</div>';

  const content = `
    <div style="font-size:13px;line-height:1.6;">
      <div style="text-align:center;padding:16px;background:rgba(168,85,247,0.05);border-radius:10px;margin-bottom:12px;">
        <div style="font-size:32px;font-weight:800;color:${colour};">${a} <span style="font-size:14px;color:var(--sub);font-weight:500;">/ 1000</span></div>
        <div style="font-size:13px;margin-top:4px;color:${colour};">${level}</div>
        <div style="font-size:11px;color:var(--muted);margin-top:6px;">Источник: ${setSrc}</div>
      </div>
      <div style="font-size:11px;color:var(--sub);line-height:1.5;margin-bottom:10px;">
        Activity влияет на показ в ленте. Низкая = пост реже виден.
        Можно купить <b>overwatch</b> — модераторы переоценят пост (±150 за раз).
      </div>
      <div style="font-size:11px;color:var(--muted);font-weight:700;text-transform:uppercase;letter-spacing:0.05em;margin:14px 0 6px;">История изменений</div>
      <div style="background:rgba(0,0,0,0.20);border-radius:8px;padding:8px 12px;max-height:160px;overflow-y:auto;">${histHtml}</div>
    </div>
  `;
  // Делаем confirm-like модалку через Dialog не получится с богатым UI — используем prompt-стайл inline
  const id = 'paModal_' + postId;
  document.getElementById(id)?.remove();
  const overlay = document.createElement('div');
  overlay.id = id;
  overlay.className = 'modal-overlay open';
  overlay.innerHTML = `
    <div class="modal-sheet" onclick="event.stopPropagation()">
      <div class="m-handle"></div>
      <div class="m-head">
        <div class="m-title">Активность поста</div>
        <button class="m-close" onclick="document.getElementById('${id}').remove()"><i class="fa-solid fa-xmark"></i></button>
      </div>
      <div style="padding:14px 18px;">${content}</div>
      <div style="padding:0 18px 18px;">
        <button onclick="buyOverwatchForPost(${postId})" style="width:100%;padding:12px;border-radius:10px;border:none;background:linear-gradient(135deg,var(--primary),var(--primary2));color:#fff;font-weight:700;cursor:pointer;font-family:inherit;font-size:13px;">
          Купить overwatch — 300 Gost
        </button>
        <div style="text-align:center;font-size:11px;color:var(--muted);margin-top:8px;line-height:1.4;">
          3+ модератора оценят, среднее изменит activity до ±150.<br>Если activity ВЫРОСЛА — следующий overwatch будет дешевле.
        </div>
      </div>
    </div>`;
  document.body.appendChild(overlay);
  overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });
}

async function buyOverwatchForPost(postId) {
  if (!await Dialog.confirm('Купить overwatch за 300 Gost?\n\n3+ модератора проверят пост, среднее их голосов (cap ±150) изменит activity. Решение нельзя отменить.', { title: 'Overwatch', okText: 'Купить' })) return;
  try {
    const r = await api(`/post/${postId}/overwatch`, 'POST');
    Dialog.alert(`Overwatch создан (#${r.request_id}). Списано ${r.price} Gost. Ждём голоса модераторов.`);
    document.getElementById('paModal_' + postId)?.remove();
    refreshWallet && refreshWallet();
  } catch(e) { showToast(e.message || 'Ошибка'); }
}

// ── Admin: поиск юзеров и прямое назначение ──
let _modSearchTimer = 0;
function modSearchUsers(q) {
  clearTimeout(_modSearchTimer);
  const box = document.getElementById('modSearchResults');
  if (!box) return;
  q = (q || '').trim();
  if (!q) { box.innerHTML = ''; return; }
  _modSearchTimer = setTimeout(async () => {
    try {
      const path = q.startsWith('@') ? `/search?q=${encodeURIComponent(q)}` : `/search?q=@${encodeURIComponent(q)}`;
      const d = await api(path);
      const users = (d.results || d.users || []).slice(0, 10);
      if (!users.length) { box.innerHTML = '<div style="color:var(--sub);font-size:12px;padding:8px;">Ничего не найдено</div>'; return; }
      box.innerHTML = users.map(u => modSearchUserCard(u)).join('');
    } catch(e) { box.innerHTML = `<div style="color:var(--red);font-size:12px;padding:8px;">${esc(e.message||'Ошибка')}</div>`; }
  }, 250);
}

function modSearchUserCard(u) {
  const userArg = jsAttr(u.username);
  return `<div style="display:flex;align-items:center;gap:8px;padding:8px;background:rgba(0,0,0,0.20);border-radius:8px;">
    <div style="width:30px;height:30px;border-radius:50%;background:linear-gradient(135deg,var(--primary),var(--primary2));display:flex;align-items:center;justify-content:center;color:#fff;font-size:12px;font-weight:700;flex-shrink:0;">${(u.display_name||u.username||'?')[0].toUpperCase()}</div>
    <div style="flex:1;min-width:0;cursor:pointer;" onclick="openFullProfile(${userArg})">
      <div style="font-weight:600;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">${esc(u.display_name||u.username)}</div>
      <div style="font-size:11px;color:var(--sub);">@${esc(u.username)}</div>
    </div>
    <button onclick="modPromoteDirect(${userArg})" style="padding:6px 10px;border-radius:8px;border:none;background:linear-gradient(135deg,var(--primary),var(--primary2));color:#fff;font-weight:600;cursor:pointer;font-family:inherit;font-size:11px;">Сделать мод</button>
  </div>`;
}

function modListCard(m) {
  const userArg = jsAttr(m.username);
  const since = m.moderator_since ? new Date(m.moderator_since*1000).toLocaleDateString('ru') : '—';
  return `<div style="display:flex;align-items:center;gap:8px;padding:8px;background:rgba(0,0,0,0.20);border-radius:8px;">
    <div style="width:30px;height:30px;border-radius:50%;background:linear-gradient(135deg,var(--primary),var(--primary2));display:flex;align-items:center;justify-content:center;color:#fff;font-size:12px;font-weight:700;flex-shrink:0;">${(m.display_name||m.username||'?')[0].toUpperCase()}</div>
    <div style="flex:1;min-width:0;cursor:pointer;" onclick="openFullProfile(${userArg})">
      <div style="font-weight:600;font-size:13px;">${esc(m.display_name||m.username)}</div>
      <div style="font-size:11px;color:var(--sub);">@${esc(m.username)} · с ${since} · рейтинг ${m.moderator_rating}/100${m.moderator_reprimands ? ' · выгов ' + m.moderator_reprimands + '/3' : ''}</div>
    </div>
    <button onclick="modDemote(${userArg})" style="padding:6px 10px;border-radius:8px;border:1px solid rgba(244,63,94,0.4);background:transparent;color:var(--red);font-weight:600;cursor:pointer;font-family:inherit;font-size:11px;">Снять</button>
  </div>`;
}

async function modPromoteDirect(username) {
  if (!await Dialog.confirm(`Сделать @${username} модератором без заявки?`, { title: 'Назначение', okText: 'Назначить' })) return;
  try {
    await api(`/mod/promote/${encodeURIComponent(username)}`, 'POST');
    showToast(`@${username} теперь модератор`);
    loadModerationScreen();
  } catch(e) { showToast(e.message || 'Ошибка'); }
}

async function modDemote(username) {
  if (!await Dialog.confirm(`Снять @${username} с роли модератора?`, { title: 'Снятие', okText: 'Снять', danger: true })) return;
  try {
    await api(`/mod/demote/${encodeURIComponent(username)}`, 'POST');
    showToast(`@${username} больше не модератор`);
    loadModerationScreen();
  } catch(e) { showToast(e.message || 'Ошибка'); }
}

async function applyForModerator() {
  if (!await Dialog.confirm('Подать заявку в модераторы за 200 Gost?\n\n200 Gost спишутся даже если заявку отклонят (это защита от спама).', { title: 'Заявка', okText: 'Подать' })) return;
  try {
    const r = await api('/mod/apply', 'POST');
    Dialog.alert(`Заявка отправлена! Quality score: ${r.quality_score}/100. Жди ответа от админа.`);
    loadModerationScreen();
  } catch(e) { showToast(e.message || 'Ошибка'); }
}

async function modDecide(appId, accept) {
  const verb = accept ? 'принять' : 'отклонить';
  if (!await Dialog.confirm(`${accept ? 'Дать роль модератора?' : 'Отклонить заявку?'}`, { title: `${verb}`, okText: 'Подтвердить' })) return;
  try {
    await api(`/mod/applications/${appId}/decide`, 'POST', { accept });
    showToast(accept ? 'Принято' : 'Отклонено');
    loadModerationScreen();
  } catch(e) { showToast(e.message || 'Ошибка'); }
}

async function owVote(reqId, delta) {
  if (!await Dialog.confirm(`Голос: ${delta > 0 ? '+' : ''}${delta} activity?\n\nИзменение нельзя отозвать.`, { title: 'Подтвердить голос', okText: 'Голосовать' })) return;
  try {
    const r = await api(`/mod/overwatch/${reqId}/vote`, 'POST', { delta });
    if (r.closed) {
      Dialog.alert(`Overwatch закрыт. Итог: ${r.delta_so_far > 0 ? '+' : ''}${r.delta_so_far} activity. Голосов: ${r.votes_count}.`);
    } else {
      showToast(`Голос засчитан (${r.votes_count}/3)`);
    }
    loadModerationScreen();
  } catch(e) { showToast(e.message || 'Ошибка'); }
}