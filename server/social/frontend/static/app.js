'use strict';

/* ── CONFIG ── */
const API_BASE = `${window.location.protocol}//${window.location.host}`;
const WS_BASE  = API_BASE.replace(/^http/, 'ws');

/* ── ICON HELPERS (reference SVG files) ── */
const ico = (name, size = 22) =>
  `<img src="icons/${name}.svg" width="${size}" height="${size}" alt="${name}" class="icon-img">`;

const ICONS = {
  like:       ico('heart',        22),
  likeFilled: ico('heart-filled', 22),
  comment:    ico('comment',      22),
  theater:    ico('theater',      22),
  share:      ico('share',        22),
  arrowLeft: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" width="16" height="16">
    <polyline points="15 18 9 12 15 6"/>
  </svg>`,
};

/* ── MOCK DATA ── */
const MOCK_POSTS = [
  { id: 1, ghost_id: 'ghost_4f2a', content: 'Ночной город глазами призрака',    hashtags: '#город #ночь #призрак',        likes: 1203,  comments: 89,   gradient: 'linear-gradient(160deg,#0a0020 0%,#2d0050 100%)' },
  { id: 2, ghost_id: 'ghost_9c1b', content: 'Когда понял что сервер лежит уже 6 часов — и ты его сам выключил', hashtags: '#dev #боль #программирование', likes: 4521, comments: 234, gradient: 'linear-gradient(160deg,#001a10 0%,#003d1a 100%)' },
  { id: 3, ghost_id: 'ghost_7e3d', content: 'Абсолютная тишина в 3 ночи',       hashtags: '#ночь #тишина #атмосфера',     likes: 892,   comments: 45,   gradient: 'linear-gradient(160deg,#1a0000 0%,#3d0010 100%)' },
  { id: 4, ghost_id: 'ghost_2a8f', content: 'Новая арт-работа готова',           hashtags: '#арт #творчество #digital',    likes: 7834,  comments: 512,  gradient: 'linear-gradient(160deg,#001a2c 0%,#003d5c 100%)' },
  { id: 5, ghost_id: 'ghost_5b6c', content: 'Почему все мессенджеры сливают ваши данные — и что с этим делать', hashtags: '#приватность #безопасность #ghostchat', likes: 15203, comments: 1089, gradient: 'linear-gradient(160deg,#1a1000 0%,#3d2000 100%)' },
  { id: 6, ghost_id: 'ghost_3e9a', content: 'Нашёл старую кассету с записями 2008 года', hashtags: '#ностальгия #воспоминания', likes: 3210, comments: 178, gradient: 'linear-gradient(160deg,#0a0a1a 0%,#1a1a3d 100%)' },
  { id: 7, ghost_id: 'ghost_8b2c', content: 'Сделал детектор лжи на Python за вечер', hashtags: '#python #проекты #dev', likes: 9870, comments: 654, gradient: 'linear-gradient(160deg,#001010 0%,#003030 100%)' },
];

/* ── STATE ── */
let posts        = [];
let currentIdx   = 0;
let likedPosts   = new Set();
let theaterPostId = null;
let theaterWS    = null;
let mockInterval = null;

/* ── DOM REFS ── */
const feedView      = document.getElementById('feed-view');
const theaterView   = document.getElementById('theater-view');
const postsContainer= document.getElementById('posts-container');
const viewerCountEl = document.getElementById('viewer-count');
const screenInner   = document.getElementById('screen-inner');
const cinemaHall    = document.getElementById('cinema-hall');
const ghostPopup    = document.getElementById('ghost-popup');
const theaterBack   = document.getElementById('theater-back');

/* ────────────────────────────────────────
   FEED
   ──────────────────────────────────────── */
async function loadPosts() {
  try {
    const res = await fetch(`${API_BASE}/api/feed`);
    if (!res.ok) throw new Error();
    posts = await res.json();
  } catch {
    posts = MOCK_POSTS;
  }
  renderFeed();
}

function renderFeed() {
  postsContainer.innerHTML = '';
  posts.forEach((post, idx) => postsContainer.appendChild(buildPostCard(post, idx)));
  observeScroll();
}

function buildPostCard(post, idx) {
  const card  = document.createElement('div');
  card.className   = 'post-card';
  card.dataset.postId  = post.id;
  card.dataset.postIdx = idx;

  const gradient = post.gradient || 'linear-gradient(160deg,#0a0020,#2d0050)';

  /* media layer */
  const media = document.createElement('div');
  media.className = 'post-media';

  if (post.media_url && post.media_type === 'video') {
    const vid = document.createElement('video');
    vid.src       = post.media_url;
    vid.muted     = true;
    vid.loop      = true;
    vid.playsInline = true;
    vid.setAttribute('playsinline', '');
    media.appendChild(vid);
  } else if (post.media_url && post.media_type === 'image') {
    const img = document.createElement('img');
    img.src = post.media_url;
    img.className = 'post-cover';
    img.style.objectFit = 'cover';
    media.appendChild(img);
  } else {
    /* gradient placeholder */
    const div = document.createElement('div');
    div.className = 'post-cover';
    div.style.background = gradient;
    media.appendChild(div);
  }
  card.appendChild(media);

  /* overlay text */
  card.insertAdjacentHTML('beforeend', `
    <div class="post-overlay">
      <div class="post-ghost-id">${escHtml(post.ghost_id)}</div>
      <div class="post-content">${escHtml(post.content)}</div>
      <div class="post-tags">${escHtml(post.hashtags || '')}</div>
    </div>

    <div class="post-actions">
      <button class="action-btn like-btn" data-post-id="${post.id}" aria-label="Лайк">
        <div class="ico">${ICONS.like}</div>
        <span class="like-count">${fmtNum(post.likes)}</span>
      </button>
      <button class="action-btn" aria-label="Комментарии">
        <div class="ico">${ICONS.comment}</div>
        <span>${fmtNum(post.comments)}</span>
      </button>
      <button class="action-btn theater-open-btn" aria-label="Открыть кинозал">
        <div class="ico">${ICONS.theater}</div>
        <span>Театр</span>
      </button>
      <button class="action-btn" aria-label="Поделиться">
        <div class="ico">${ICONS.share}</div>
        <span>Поделиться</span>
      </button>
    </div>

    <button class="theater-edge" aria-label="Кинозал">
      ${ICONS.arrowLeft}
    </button>
  `);

  /* events */
  card.querySelector('.like-btn').addEventListener('click', e => {
    e.stopPropagation();
    toggleLike(post, card.querySelector('.like-btn'));
  });

  const openFn = () => openTheater(post);
  card.querySelector('.theater-open-btn').addEventListener('click', e => { e.stopPropagation(); openFn(); });
  card.querySelector('.theater-edge').addEventListener('click',     e => { e.stopPropagation(); openFn(); });

  addSwipe(card, openFn);
  return card;
}

/* ── like toggle ── */
function toggleLike(post, btn) {
  const icoEl    = btn.querySelector('.ico');
  const countEl  = btn.querySelector('.like-count');
  if (likedPosts.has(post.id)) {
    likedPosts.delete(post.id);
    btn.classList.remove('liked');
    icoEl.innerHTML = ICONS.like;
    post.likes--;
  } else {
    likedPosts.add(post.id);
    btn.classList.add('liked');
    icoEl.innerHTML = ICONS.likeFilled;
    post.likes++;
    fetch(`${API_BASE}/api/posts/${post.id}/like`, { method: 'POST' }).catch(() => {});
    floatHeart();
  }
  countEl.textContent = fmtNum(post.likes);
}

function floatHeart() {
  const el = document.createElement('div');
  el.innerHTML = ICONS.likeFilled;
  el.style.cssText = `
    position:fixed;left:50%;top:50%;z-index:999;pointer-events:none;
    transform:translate(-50%,-50%) scale(0);
    transition:transform .4s cubic-bezier(.2,1.6,.4,1), opacity .4s .22s;
    opacity:1; color:#D97757; width:64px; height:64px;
  `;
  document.body.appendChild(el);
  requestAnimationFrame(() => {
    el.style.transform = 'translate(-50%,-50%) scale(1)';
    el.style.opacity   = '0';
  });
  setTimeout(() => el.remove(), 700);
}

/* ── scroll tracking + video autoplay ── */
function observeScroll() {
  const io = new IntersectionObserver(entries => {
    entries.forEach(e => {
      const vid = e.target.querySelector('video');
      if (e.isIntersecting) {
        currentIdx = Number(e.target.dataset.postIdx);
        if (vid) vid.play().catch(() => {});
      } else {
        if (vid) vid.pause();
      }
    });
  }, { root: postsContainer, threshold: .6 });

  document.querySelectorAll('.post-card').forEach(c => io.observe(c));
}

/* ── swipe left → theater ── */
function addSwipe(el, onLeft) {
  let sx = 0, sy = 0;
  el.addEventListener('touchstart', e => { sx = e.touches[0].clientX; sy = e.touches[0].clientY; }, { passive: true });
  el.addEventListener('touchend',   e => {
    const dx = e.changedTouches[0].clientX - sx;
    const dy = e.changedTouches[0].clientY - sy;
    if (Math.abs(dx) > Math.abs(dy) && dx < -55) onLeft();
  }, { passive: true });
}

/* ────────────────────────────────────────
   THEATER
   ──────────────────────────────────────── */
function openTheater(post) {
  theaterPostId = String(post.id);

  /* populate screen */
  const gradient = post.gradient || 'linear-gradient(160deg,#0a0020,#2d0050)';
  screenInner.style.background = gradient;
  screenInner.innerHTML = `
    <div>
      <div style="font-size:11px;color:rgba(255,255,255,.5);margin-bottom:6px">${escHtml(post.ghost_id)}</div>
      <div style="font-size:12px;font-weight:500;line-height:1.45;max-width:220px;margin:auto">${escHtml(post.content)}</div>
    </div>
  `;

  buildHall();
  feedView.classList.remove('active');
  theaterView.classList.add('active');
  connectWS(theaterPostId);
}

function closeTheater() {
  theaterView.classList.remove('active');
  feedView.classList.add('active');
  disconnectWS();
  theaterPostId = null;
  viewerCountEl.textContent = '0';
}

/* ── build hall (5 rows × 8 seats) ── */
const ROWS = 5, COLS = 8;

function buildHall() {
  cinemaHall.innerHTML = '';
  for (let r = 0; r < ROWS; r++) {
    const row = document.createElement('div');
    row.className  = 'seat-row';
    row.dataset.row = r;
    for (let c = 0; c < COLS; c++) {
      const seat = document.createElement('div');
      seat.className        = 'seat';
      seat.dataset.seatIdx  = r * COLS + c;
      seat.innerHTML        = `<div class="seat-backrest"></div>`;
      seat.addEventListener('click', () => { if (seat.classList.contains('occupied')) showGhostPopup(); });
      row.appendChild(seat);
    }
    cinemaHall.appendChild(row);
  }
}

/* ghost shape HTML */
function ghostHTML() {
  return `<div class="ghost-shape"></div>`;
}

function updateSeats(count) {
  const seats    = cinemaHall.querySelectorAll('.seat');
  const total    = ROWS * COLS;
  const toFill   = Math.min(count, total);
  const fillFrom = total - toFill;

  seats.forEach(seat => {
    const idx = Number(seat.dataset.seatIdx);
    if (idx >= fillFrom) {
      if (!seat.classList.contains('occupied')) {
        seat.classList.add('occupied');
        seat.innerHTML = ghostHTML();
        seat.addEventListener('click', () => showGhostPopup());
      }
    } else {
      if (seat.classList.contains('occupied')) {
        seat.classList.remove('occupied');
        seat.innerHTML = `<div class="seat-backrest"></div>`;
      }
    }
  });
}

/* ── ghost popup ── */
function showGhostPopup() {
  ghostPopup.classList.remove('hidden');
}

document.getElementById('popup-close').addEventListener('click',  () => ghostPopup.classList.add('hidden'));
document.getElementById('popup-open-profile').addEventListener('click', () => ghostPopup.classList.add('hidden'));
ghostPopup.addEventListener('click', e => { if (e.target === ghostPopup) ghostPopup.classList.add('hidden'); });

/* ── WebSocket ── */
function connectWS(postId) {
  try {
    theaterWS = new WebSocket(`${WS_BASE}/ws/theater/${postId}`);
    theaterWS.onmessage = e => {
      const msg = JSON.parse(e.data);
      if (msg.type === 'viewer_count') applyCount(msg.count);
    };
    theaterWS.onerror = () => startMock();
    theaterWS.onclose = () => { theaterWS = null; };
    theaterWS._ping = setInterval(() => {
      if (theaterWS?.readyState === WebSocket.OPEN) theaterWS.send('ping');
    }, 25000);
  } catch {
    startMock();
  }
}

function disconnectWS() {
  if (theaterWS) {
    clearInterval(theaterWS._ping);
    theaterWS.close();
    theaterWS = null;
  }
  stopMock();
}

function applyCount(n) {
  viewerCountEl.textContent = n;
  updateSeats(n);
}

/* mock viewer count when server offline */
function startMock() {
  let n = Math.floor(Math.random() * 10) + 3;
  applyCount(n);
  mockInterval = setInterval(() => {
    n = Math.max(1, Math.min(ROWS * COLS - 1, n + (Math.random() < .5 ? 1 : -1)));
    applyCount(n);
  }, 2800);
}
function stopMock() {
  clearInterval(mockInterval);
  mockInterval = null;
}

/* ────────────────────────────────────────
   BOTTOM NAV
   ──────────────────────────────────────── */
theaterBack.addEventListener('click', closeTheater);

document.querySelectorAll('.nav-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    if (btn.dataset.tab === 'feed' && theaterView.classList.contains('active')) closeTheater();
  });
});

/* ── keyboard shortcuts (desktop) ── */
document.addEventListener('keydown', e => {
  if (!theaterView.classList.contains('active') && e.key === 'ArrowLeft')  openTheater(posts[currentIdx]);
  if ( theaterView.classList.contains('active') && e.key === 'ArrowRight') closeTheater();
  if (e.key === 'Escape') {
    if (!ghostPopup.classList.contains('hidden')) ghostPopup.classList.add('hidden');
    else if (theaterView.classList.contains('active')) closeTheater();
  }
});

/* ────────────────────────────────────────
   UTILS
   ──────────────────────────────────────── */
function fmtNum(n) {
  if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
  if (n >= 1000)    return (n / 1000).toFixed(1) + 'K';
  return String(n);
}

function escHtml(s) {
  return String(s ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

/* ── BOOT ── */
loadPosts();
