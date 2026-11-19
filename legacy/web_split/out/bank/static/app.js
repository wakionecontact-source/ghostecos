// ═══════════════════════════════════════════════════════════════════════════
// Bank: Gost + Soul + NFT-market
// ═══════════════════════════════════════════════════════════════════════════
const API = '/api/soc';
let token = localStorage.getItem('gs_token');
let me = null;
try { me = JSON.parse(localStorage.getItem('gs_me') || 'null'); } catch(_) {}
let _walDailyTimer = null;
let _ws = null, _wsReconnectDelay = 1000, _wsAuthFail = false;
let _activeCurrency = localStorage.getItem('bank_active_cur') || 'soul';
let _activeMarketSlug = ''; // фильтр маркета (пусто = все)

function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');}
// JS-context escape для inline onclick — esc() ловит только HTML-context.
// JSON.stringify даёт правильно квотированную JS-строку, потом обрамляем в HTML-context через esc.
function jsArg(s){return esc(JSON.stringify(String(s == null ? '' : s)));}
// Whitelist для CSS-цвета чтобы исключить injection в style=""
function safeColor(c){return /^#[0-9a-fA-F]{6}$/.test(c) ? c : '#a855f7';}
// Whitelist для currency
function safeCur(c){return c === 'gost' || c === 'soul' || c === 'prem' ? c : 'gost';}
function ini(n){return n ? n[0].toUpperCase() : '?';}
function fmtNum(n){return (n||0).toLocaleString('ru-RU');}
function showToast(msg, err=false){
  const t = document.getElementById('toast');
  t.textContent = msg; t.className = 'toast' + (err ? ' err' : '');
  t.classList.add('show'); setTimeout(() => t.classList.remove('show'), 2600);
}
function ago(ts){
  const d = new Date(ts.includes('Z') || ts.includes('+') ? ts : ts + 'Z');
  const s = Math.floor((Date.now() - d) / 1000);
  if (s < 60) return 'только что';
  if (s < 3600) return Math.floor(s / 60) + ' мин назад';
  if (s < 86400) return Math.floor(s / 3600) + ' ч назад';
  return Math.floor(s / 86400) + ' д назад';
}

async function api(path, method='GET', body=null){
  const h = { 'Content-Type': 'application/json' };
  if (token) h['Authorization'] = 'Bearer ' + token;
  const ctrl = new AbortController();
  const tid = setTimeout(() => ctrl.abort(), 20000);
  const opts = { method, headers: h, signal: ctrl.signal };
  if (body) opts.body = JSON.stringify(body);
  let r;
  try { r = await fetch(API + path, opts); }
  finally { clearTimeout(tid); }
  if (!r.ok) {
    const text = await r.text();
    let msg = text; try { msg = JSON.parse(text).detail || text; } catch(_) {}
    const e = new Error(msg); e.status = r.status; throw e;
  }
  return r.json();
}

function setBalance(elId, val){
  const el = document.getElementById(elId);
  if (!el) return;
  const prev = +(el.textContent.replace(/\s/g, '')) || 0;
  el.textContent = fmtNum(val);
  if (val > prev) {
    el.classList.remove('bump'); void el.offsetWidth; el.classList.add('bump');
  }
}

// ── Currency switcher ──
function selectCurrency(cur){
  if (cur === _activeCurrency) return;
  _activeCurrency = cur;
  localStorage.setItem('bank_active_cur', cur);
  document.querySelectorAll('.cur-card').forEach(c => c.classList.toggle('active', c.dataset.currency === cur));
  document.querySelectorAll('.panel').forEach(p => p.classList.toggle('active', p.dataset.panel === cur));
}

// ── SVG NFT icons (генерируем динамически по slug) ──
const NFT_SVG = {
  ghost: `<svg viewBox="0 0 80 80" class="nft-ghost"><ellipse cx="40" cy="35" rx="22" ry="26" fill="currentColor"/><path d="M18 55 L25 65 L32 55 L40 65 L48 55 L55 65 L62 55 L62 35 L18 35 Z" fill="currentColor"/><circle cx="32" cy="32" r="3.5" fill="#1e293b"/><circle cx="48" cy="32" r="3.5" fill="#1e293b"/><ellipse cx="40" cy="44" rx="3" ry="2" fill="#1e293b" opacity="0.6"/></svg>`,
  moon: `<svg viewBox="0 0 80 80" class="nft-moon"><circle cx="40" cy="40" r="26" fill="currentColor"/><circle cx="32" cy="32" r="3.5" fill="#94a3b8" opacity="0.5"/><circle cx="50" cy="44" r="2.5" fill="#94a3b8" opacity="0.5"/><circle cx="44" cy="52" r="3" fill="#94a3b8" opacity="0.5"/><circle cx="28" cy="46" r="2" fill="#94a3b8" opacity="0.5"/></svg>`,
  star: `<svg viewBox="0 0 80 80" class="nft-star"><path d="M40 10 L48 32 L72 32 L52 46 L60 70 L40 56 L20 70 L28 46 L8 32 L32 32 Z" fill="currentColor" stroke="#fff" stroke-width="0.5"/></svg>`,
  flame: `<svg viewBox="0 0 80 80" class="nft-flame"><path d="M40 12 C 28 28, 22 42, 28 56 C 30 64, 36 70, 40 70 C 44 70, 50 64, 52 56 C 58 42, 52 28, 40 12 Z" fill="currentColor"/><path d="M40 28 C 34 38, 32 48, 36 56 C 38 62, 42 64, 44 60 C 48 52, 46 40, 40 28 Z" fill="#fcd34d"/><ellipse cx="40" cy="56" rx="3" ry="6" fill="#fff"/></svg>`,
  heart: `<svg viewBox="0 0 80 80" class="nft-heart"><path d="M40 64 C 24 50, 8 38, 14 22 C 18 12, 32 12, 40 26 C 48 12, 62 12, 66 22 C 72 38, 56 50, 40 64 Z" fill="currentColor"/><path d="M28 22 C 24 26, 24 32, 28 36" stroke="#fff" stroke-width="2" fill="none" opacity="0.5"/></svg>`,
  bolt: `<svg viewBox="0 0 80 80" class="nft-bolt"><path d="M44 8 L20 44 L36 44 L28 72 L60 32 L42 32 L52 8 Z" fill="currentColor" stroke="#fff" stroke-width="0.5"/></svg>`,
  crystal: `<svg viewBox="0 0 80 80" class="nft-crystal"><path d="M40 8 L60 28 L40 72 L20 28 Z" fill="currentColor" stroke="#fff" stroke-width="0.8"/><path d="M40 8 L60 28 L40 28 Z" fill="rgba(255,255,255,0.4)"/><path d="M40 28 L60 28 L40 72 Z" fill="rgba(0,0,0,0.15)"/><line x1="40" y1="8" x2="40" y2="72" stroke="#fff" stroke-width="0.8"/></svg>`,
  eye: `<svg viewBox="0 0 80 80" class="nft-eye"><ellipse cx="40" cy="40" rx="32" ry="20" fill="#fff"/><ellipse cx="40" cy="40" rx="32" ry="20" fill="none" stroke="#1e293b" stroke-width="1.5"/><g class="pupil"><circle cx="40" cy="40" r="11" fill="#0891b2"/><circle cx="40" cy="40" r="6" fill="#1e293b"/><circle cx="37" cy="37" r="2" fill="#fff"/></g><ellipse cx="40" cy="40" rx="32" ry="20" fill="#1e293b" class="eye-lid"/></svg>`,
  key: `<svg viewBox="0 0 80 80" class="nft-key"><circle cx="25" cy="25" r="14" fill="none" stroke="currentColor" stroke-width="4"/><circle cx="25" cy="25" r="5" fill="currentColor"/><rect x="36" y="22" width="36" height="6" rx="2" fill="currentColor"/><rect x="56" y="28" width="4" height="8" fill="currentColor"/><rect x="64" y="28" width="4" height="6" fill="currentColor"/><rect class="glint" x="14" y="36" width="3" height="40" fill="rgba(255,255,255,0.6)" transform="rotate(-45 40 40)"/></svg>`,
  crown: `<svg viewBox="0 0 80 80" class="nft-crown"><path d="M14 56 L18 30 L30 44 L40 22 L50 44 L62 30 L66 56 Z" fill="#fcd34d" stroke="#fbbf24" stroke-width="1.5"/><rect x="14" y="56" width="52" height="10" rx="2" fill="#fbbf24"/><circle class="gem" cx="40" cy="34" r="3.5" fill="#f43f5e"/><circle class="gem g2" cx="24" cy="50" r="2.5" fill="#3b82f6"/><circle class="gem g3" cx="56" cy="50" r="2.5" fill="#22c55e"/><rect x="14" y="62" width="52" height="2" fill="rgba(255,255,255,0.4)"/></svg>`,
};
function nftSvg(slug){return NFT_SVG[slug] || NFT_SVG.ghost;}
function rarityIcon(r){return r === 'legend' ? '<i class="fa-solid fa-crown"></i>' : r === 'rare' ? '<i class="fa-solid fa-star"></i>' : '';}
function verifiedBadge(){return '<i class="fa-solid fa-circle-check verified" title="Официальный аккаунт"></i>';}
function curIcon(cur){return cur === 'gost' ? 'fa-ghost' : 'fa-fire';}
function curName(cur){return cur === 'gost' ? 'Gost' : 'Soul';}
function pricePill(amount, currency){const c = safeCur(currency); return `<span class="cur-pill ${c}"><i class="fa-solid ${curIcon(c)}"></i>${fmtNum(amount)}</span>`;}

// ═══════════════ Wallet (Gost + Soul) ═══════════════
async function loadWallet(){
  try {
    const [w, txGost, state, txSoul] = await Promise.all([
      api('/wallet'), api('/wallet/tx'), api('/economy/state'), api('/soul/tx')
    ]);
    setBalance('bGost', w.balance.gost || 0);
    setBalance('bSoul', w.balance.soul || 0);
    setBalance('bPrem', w.balance.prem || 0);
    document.getElementById('claimAmt').textContent = w.daily_reward;
    setupDailyClaim(w.next_daily_in || 0);
    renderGostTx(txGost.transactions || []);
    // Реф-блок — параллельно, не блокируем кошелёк если упадёт
    loadRefBlock().catch(() => {});
    // Soul state
    document.getElementById('soulRate').textContent = state.rate_paused ? '⏸ паузa' : fmtNum(state.soul_rate_gost);
    document.getElementById('sysBal').textContent = fmtNum(state.system_balance);
    document.getElementById('sysCap').textContent = fmtNum(state.cap);
    document.getElementById('burnedTotal').textContent = fmtNum(state.burned_total);
    renderSoulTx(txSoul.transactions || []);
  } catch(e) {
    console.error('[wallet]', e);
    if (e.status === 401) { showAuth(); return; }
    showToast('Не удалось загрузить кошелёк', true);
  }
}

function setupDailyClaim(secondsLeft){
  const btn = document.getElementById('claimBtn');
  const hint = document.getElementById('claimHint');
  const cd = document.getElementById('claimCd');
  clearInterval(_walDailyTimer);
  if (secondsLeft <= 0) {
    btn.disabled = false; btn.style.display = ''; hint.style.display = 'none';
    return;
  }
  btn.disabled = true; hint.style.display = '';
  const tick = () => {
    if (secondsLeft <= 0) { clearInterval(_walDailyTimer); setupDailyClaim(0); return; }
    const h = Math.floor(secondsLeft / 3600);
    const m = Math.floor((secondsLeft % 3600) / 60);
    const s = secondsLeft % 60;
    cd.textContent = `${String(h).padStart(2,'0')}:${String(m).padStart(2,'0')}:${String(s).padStart(2,'0')}`;
    secondsLeft--;
  };
  tick(); _walDailyTimer = setInterval(tick, 1000);
}

async function claimDaily(){
  const btn = document.getElementById('claimBtn');
  btn.disabled = true;
  try {
    const r = await api('/wallet/claim_daily', 'POST');
    if (r.credited > 0) showToast(`+${r.credited} Gost получено!`);
    await loadWallet();
  } catch(e) {
    showToast(e.message || 'Не удалось получить бонус', true);
    btn.disabled = false;
  }
}

const TX_GOST = {
  register:{icon:'fa-trophy',label:'Welcome бонус'},
  daily:{icon:'fa-gift',label:'Ежедневный бонус'},
  post:{icon:'fa-pen',label:'За пост'},
  react:{icon:'fa-heart',label:'Лайк на твой пост'},
  comment:{icon:'fa-comment',label:'Коммент на твой пост'},
  follow:{icon:'fa-user-plus',label:'Новый подписчик'},
  spend:{icon:'fa-cart-shopping',label:'Покупка'},
  admin:{icon:'fa-shield',label:'От администрации'},
};
function renderGostTx(list){
  const root = document.getElementById('txList');
  if (!list.length) { root.innerHTML = '<div class="tx-empty"><i class="fa-solid fa-coins"></i>Пока пусто. Активничай в GhostSocial — Gost начнут капать.</div>'; return; }
  root.innerHTML = list.map(t => {
    const meta = TX_GOST[t.source] || {icon:'fa-coins', label:t.source};
    const sign = t.delta > 0 ? '+' : '';
    const cls = 'tx-amount ' + (t.delta < 0 ? 'neg' : 'pos');
    const actor = t.actor ? ` · @${esc(t.actor.username)}` : '';
    return `<div class="tx-item"><div class="tx-icon"><i class="fa-solid ${meta.icon}"></i></div><div class="tx-body"><div class="tx-title">${esc(meta.label)}</div><div class="tx-meta">${ago(t.created_at)}${actor}</div></div><div class="${cls}">${sign}${t.delta} ${t.currency}</div></div>`;
  }).join('');
}

const TX_SOUL = {
  admin_emit:{icon:'fa-shield',label:'Эмиссия'},
  transfer_in:{icon:'fa-arrow-down',label:'Перевод от'},
  transfer_out:{icon:'fa-arrow-up',label:'Перевод'},
  nft_buy:{icon:'fa-cart-shopping',label:'Покупка NFT'},
  nft_sell:{icon:'fa-tag',label:'Продажа NFT'},
  nft_fee:{icon:'fa-paper-plane',label:'Передача NFT'},
  fee:{icon:'fa-receipt',label:'Комиссия'},
  burn:{icon:'fa-fire',label:'Сожжено'},
};
function renderSoulTx(list){
  const root = document.getElementById('soulTxList');
  if (!list.length) { root.innerHTML = '<div class="tx-empty"><i class="fa-solid fa-fire"></i>История Soul-транзакций пуста. Начните с покупки NFT на маркете.</div>'; return; }
  root.innerHTML = list.map(t => {
    const meta = TX_SOUL[t.source] || {icon:'fa-fire', label:t.source};
    const sign = t.delta > 0 ? '+' : '';
    const cls = 'tx-amount ' + (t.delta < 0 ? 'neg' : (t.delta > 0 ? 'pos' : ''));
    const counter = t.counter ? ` · @${esc(t.counter.username)}${t.counter.is_official ? ' ✓' : ''}` : '';
    const note = t.note ? ` · ${esc(t.note)}` : '';
    return `<div class="tx-item"><div class="tx-icon" style="color:var(--soul);background:rgba(236,72,153,0.12);"><i class="fa-solid ${meta.icon}"></i></div><div class="tx-body"><div class="tx-title">${esc(meta.label)}</div><div class="tx-meta">${ago(t.created_at)}${counter}${note}</div></div><div class="${cls}">${t.delta === 0 ? '—' : sign + fmtNum(t.delta) + ' Soul'}</div></div>`;
  }).join('');
}

// ═══════════════ NFT: каталог, мой, маркет ═══════════════
async function loadCatalog(){
  try {
    const r = await api('/nft/catalog');
    renderCatalog(r.catalog || []);
    renderMarketFilters(r.catalog || []);
  } catch(e) { console.error('[catalog]', e); }
}
function renderCatalog(items){
  const root = document.getElementById('catGrid');
  root.innerHTML = items.map(it => {
    // Floor: показываем Gost-цену если есть (первичные продажи), иначе Soul
    let floorHTML;
    if (it.floor_gost != null) floorHTML = `от ${pricePill(it.floor_gost, 'gost')}`;
    else if (it.floor_soul != null) floorHTML = `от ${pricePill(it.floor_soul, 'soul')}`;
    else floorHTML = `от ${pricePill(it.start_price_gost, 'gost')}`;
    return `
    <div class="cat-card" data-rarity="${it.rarity}" onclick="openCatalogModal(${jsArg(it.slug)})" title="${esc(it.description)}">
      <div class="cat-art">${nftArt(it)}</div>
      <div class="cat-name">${esc(it.name)}</div>
      <div class="cat-meta">${rarityIcon(it.rarity)} ${it.listed}/${it.max_supply}</div>
      <div class="cat-floor">${floorHTML}</div>
    </div>`;
  }).join('');
}
function renderMarketFilters(items){
  const wrap = document.getElementById('marketFilters');
  wrap.innerHTML = '<button class="mf-chip ' + (_activeMarketSlug === '' ? 'active' : '') + '" data-slug="" onclick="setMarketFilter(\'\')">Все</button>' +
    items.map(it => `<button class="mf-chip ${_activeMarketSlug === it.slug ? 'active' : ''}" data-slug="${esc(it.slug)}" onclick="setMarketFilter(${jsArg(it.slug)})">${esc(it.name)}</button>`).join('');
}
function setMarketFilter(slug){
  _activeMarketSlug = slug;
  document.querySelectorAll('.mf-chip').forEach(c => c.classList.toggle('active', c.dataset.slug === slug));
  loadMarket();
}

async function loadMyNfts(){
  try {
    const r = await api('/nft/my');
    const nfts = r.nfts || [];
    document.getElementById('myNftCount').textContent = nfts.length;
    const root = document.getElementById('myNftList');
    if (!nfts.length) { root.innerHTML = '<div class="my-empty"><i class="fa-solid fa-image"></i>Пока нет NFT. Купите первый на маркете или дождитесь подарка.</div>'; return; }
    root.innerHTML = '<div class="list-grid">' + nfts.map(n => `
      <div class="lst-card" data-rarity="${n.catalog.rarity}" onclick="openMyNftModal(${n.id})">
        <div class="lst-art">${nftArt(n.catalog)}</div>
        <div class="lst-name">${esc(n.catalog.name)}</div>
        <div class="lst-serial">#${n.serial}/${n.catalog.max_supply}</div>
        ${n.listing ? `<div class="lst-price">${pricePill(n.listing.price, n.listing.currency)}</div>` : `<button class="lst-btn">Управлять</button>`}
      </div>`).join('') + '</div>';
  } catch(e) { console.error('[my nfts]', e); }
}

let _marketOffset = 0;
let _marketHasMore = false;
async function loadMarket(append=false){
  const root = document.getElementById('marketGrid');
  if (!append) {
    root.innerHTML = '<div class="loader" style="grid-column:1/-1;"><div class="spinner"></div></div>';
    _marketOffset = 0;
  }
  // Убрать старую кнопку «Показать ещё» если есть
  const oldBtn = document.getElementById('marketMoreBtn');
  if (oldBtn) oldBtn.remove();
  try {
    const params = new URLSearchParams();
    if (_activeMarketSlug) params.set('slug', _activeMarketSlug);
    params.set('offset', _marketOffset);
    const r = await api('/nft/listings?' + params.toString());
    if (!r.listings.length && !append) {
      root.innerHTML = '<div class="my-empty" style="grid-column:1/-1;"><i class="fa-solid fa-store-slash"></i>Здесь пусто</div>';
      _marketHasMore = false;
      return;
    }
    const html = r.listings.map(n => {
      const isMine = me && n.owner.id === me.id;
      const ownerBadge = n.owner.is_official ? verifiedBadge() : '';
      const cur = n.listing.currency;
      return `<div class="lst-card" data-rarity="${n.catalog.rarity}" onclick="openListingModal(${n.id})">
        <div class="lst-art">${nftArt(n.catalog)}</div>
        <div class="lst-name">${esc(n.catalog.name)}</div>
        <div class="lst-serial">#${n.serial}/${n.catalog.max_supply}</div>
        <div class="lst-owner">${ownerBadge}@${esc(n.owner.username)}</div>
        <div class="lst-price">${pricePill(n.listing.price, cur)}</div>
        ${isMine ? '<button class="lst-btn own" onclick="event.stopPropagation();unlistNft(' + n.id + ')">Снять</button>' : '<button class="lst-btn" onclick="event.stopPropagation();buyListing(' + n.id + ')">Купить</button>'}
      </div>`;
    }).join('');
    if (append) root.insertAdjacentHTML('beforeend', html);
    else root.innerHTML = html;
    _marketOffset += r.listings.length;
    _marketHasMore = !!r.has_more;
    // Кнопка «Показать ещё» — после грида
    if (_marketHasMore) {
      const section = document.getElementById('marketSection');
      const btn = document.createElement('button');
      btn.id = 'marketMoreBtn';
      btn.className = 'load-more';
      btn.textContent = 'Показать ещё';
      btn.onclick = () => { btn.disabled = true; btn.textContent = 'Загрузка...'; loadMarket(true); };
      section.appendChild(btn);
    }
  } catch(e) { console.error('[market]', e); if (!append) root.innerHTML = '<div class="my-empty" style="grid-column:1/-1;">Ошибка загрузки</div>'; }
}

// ═══════════════ Модалки ═══════════════
function openModal(id){document.getElementById(id).classList.add('open');}
function closeModal(id){document.getElementById(id).classList.remove('open');}

async function openCatalogModal(slug){
  try {
    const r = await api('/nft/catalog');
    const it = r.catalog.find(x => x.slug === slug);
    if (!it) return;
    const floorRows = [];
    if (it.floor_gost != null) floorRows.push(`<div class="modal-row"><span>Первичная цена (от GhostEcos)</span><span class="v">${pricePill(it.floor_gost, 'gost')}</span></div>`);
    if (it.floor_soul != null) floorRows.push(`<div class="modal-row"><span>Минимальная P2P</span><span class="v">${pricePill(it.floor_soul, 'soul')}</span></div>`);
    if (!floorRows.length) floorRows.push(`<div class="modal-row"><span>Стартовая цена</span><span class="v">${pricePill(it.start_price_gost, 'gost')}</span></div>`);
    const cont = document.getElementById('nftModalContent');
    cont.innerHTML = `
      <div class="modal-head">
        <div class="modal-title">${esc(it.name)}</div>
        <button class="modal-close" onclick="closeModal('nftModal')"><i class="fa-solid fa-xmark"></i></button>
      </div>
      <div class="modal-art">${nftSvg(it.slug)}</div>
      <div class="modal-info">
        <h3>${esc(it.name)} ${rarityIcon(it.rarity)}</h3>
        <div class="sub">${esc(it.description)}</div>
      </div>
      <div>
        <div class="modal-row"><span>Создатель</span><b>@${esc(it.creator.username)} ${it.creator.is_official ? verifiedBadge() : ''}</b></div>
        <div class="modal-row"><span>Тираж</span><b>${it.minted}/${it.max_supply}</b></div>
        <div class="modal-row"><span>На рынке</span><b>${it.listed}</b></div>
        ${floorRows.join('')}
      </div>
      <div class="modal-actions">
        <button class="btn ghost" onclick="closeModal('nftModal')">Закрыть</button>
        <button class="btn primary" onclick="closeModal('nftModal');setMarketFilter(${jsArg(slug)});scrollToSection('marketSection');">Купить на маркете</button>
      </div>`;
    openModal('nftModal');
  } catch(e) { console.error(e); }
}

async function openListingModal(nftId){
  try {
    // Берём один листинг точечно через /nft/my (если мой) или через /listings (по offset)
    // Здесь — упрощённо: достаём из последнего загруженного списка
    const r = await api(`/nft/listings?offset=0`);
    // Если не нашли в первой странице — попробуем все валюты через slug-pass: ищем по nftId перебором
    let n = r.listings.find(x => x.id === nftId);
    if (!n) {
      // ещё пара попыток с большими offset (если очень глубоко)
      for (let off = 30; off < 300 && !n; off += 30) {
        const r2 = await api(`/nft/listings?offset=${off}`);
        n = r2.listings.find(x => x.id === nftId);
        if (!r2.has_more) break;
      }
    }
    if (!n) { showToast('Уже продан', true); loadMarket(); return; }
    const isMine = me && n.owner.id === me.id;
    const ownerBadge = n.owner.is_official ? verifiedBadge() : '';
    const cur = n.listing.currency;
    const cont = document.getElementById('nftModalContent');
    const rows = [`<div class="modal-row"><span>Продавец</span><b>${ownerBadge}@${esc(n.owner.username)}</b></div>`];
    rows.push(`<div class="modal-row"><span>Цена</span><span class="v">${pricePill(n.listing.price, cur)}</span></div>`);
    let total = n.listing.price;
    if (cur === 'soul') {
      const fee = Math.max(1, Math.ceil(n.listing.price * 0.10));
      total = n.listing.price + fee;
      rows.push(`<div class="modal-row"><span>Комиссия маркета (10%)</span><span class="v">${pricePill(fee, 'soul')}</span></div>`);
      rows.push(`<div class="modal-row"><span><b>Итого</b></span><span class="v"><b>${pricePill(total, 'soul')}</b></span></div>`);
    } else {
      rows.push(`<div class="modal-row" style="color:var(--sub);font-size:11px;"><span>Первичная продажа</span><span>без комиссии</span></div>`);
    }
    cont.innerHTML = `
      <div class="modal-head">
        <div class="modal-title">${cur === 'gost' ? 'Первичная продажа' : 'NFT в продаже'}</div>
        <button class="modal-close" onclick="closeModal('nftModal')"><i class="fa-solid fa-xmark"></i></button>
      </div>
      <div class="modal-art">${nftSvg(n.catalog.slug)}</div>
      <div class="modal-info">
        <h3>${esc(n.catalog.name)} ${rarityIcon(n.catalog.rarity)}</h3>
        <div class="sub">#${n.serial} из ${n.catalog.max_supply}</div>
      </div>
      <div>${rows.join('')}</div>
      <div class="modal-actions">
        <button class="btn ghost" onclick="closeModal('nftModal')">Отмена</button>
        ${isMine ? `<button class="btn danger" onclick="unlistNft(${n.id})">Снять с продажи</button>` : `<button class="btn primary" onclick="buyListing(${n.id})">Купить за ${pricePill(total, cur)}</button>`}
      </div>`;
    openModal('nftModal');
  } catch(e) { console.error(e); }
}

async function openMyNftModal(nftId){
  try {
    const r = await api('/nft/my');
    const n = r.nfts.find(x => x.id === nftId);
    if (!n) return;
    const cont = document.getElementById('nftModalContent');
    const listed = !!n.listing;
    const listedHere = listed ? `<div class="modal-row"><span>Сейчас на маркете</span><span class="v">${pricePill(n.listing.price, n.listing.currency)}</span></div>` : '';
    cont.innerHTML = `
      <div class="modal-head">
        <div class="modal-title">Мой NFT</div>
        <button class="modal-close" onclick="closeModal('nftModal')"><i class="fa-solid fa-xmark"></i></button>
      </div>
      <div class="modal-art">${nftSvg(n.catalog.slug)}</div>
      <div class="modal-info">
        <h3>${esc(n.catalog.name)} ${rarityIcon(n.catalog.rarity)}</h3>
        <div class="sub">#${n.serial} из ${n.catalog.max_supply}</div>
      </div>
      ${listedHere}
      <div class="field" style="margin-top:14px;">
        <label>${listed ? 'Изменить цену (Soul)' : 'Цена на маркете (Soul)'}</label>
        <input id="listPrice" type="number" min="1" value="${listed ? n.listing.price : ''}" placeholder="например 10">
        <div class="hint">Юзеры выставляют только за Soul. С продажи 10% комиссия системе.</div>
      </div>
      <div class="modal-actions">
        ${listed ? `<button class="btn danger" onclick="unlistNft(${n.id})">Снять</button>` : '<button class="btn ghost" onclick="closeModal(\'nftModal\')">Отмена</button>'}
        <button class="btn primary" onclick="listMyNft(${n.id})">${listed ? 'Обновить' : 'Выставить'}</button>
      </div>
      <div class="modal-actions">
        <button class="btn ghost" onclick="openTransferNft(${n.id})"><i class="fa-solid fa-paper-plane"></i> Передать (−1 Soul)</button>
      </div>`;
    openModal('nftModal');
  } catch(e) { console.error(e); }
}

// Глобальный in-flight guard для финансовых операций — защита от двойных кликов
const _inFlight = new Set();
async function withLock(key, fn) {
  if (_inFlight.has(key)) { showToast('Уже выполняется...', true); return; }
  _inFlight.add(key);
  try { return await fn(); } finally { _inFlight.delete(key); }
}

async function buyListing(nftId){
  return withLock('buy:'+nftId, async () => {
  try {
    const r = await api(`/nft/buy/${nftId}`, 'POST');
    const cur = r.currency || 'soul';
    const total = (r.price || 0) + (r.fee || 0);
    showToast(`Куплено! −${fmtNum(total)} ${curName(cur)}`);
    closeModal('nftModal');
    await Promise.all([loadWallet(), loadMyNfts(), loadMarket(), loadCatalog()]);
  } catch(e) { showToast(e.message || 'Ошибка покупки', true); }
  });
}

async function listMyNft(nftId){
  const price = +document.getElementById('listPrice').value;
  if (!price || price < 1) { showToast('Введите цену', true); return; }
  try {
    await api('/nft/list', 'POST', { nft_id: nftId, price_soul: price });
    showToast(`Выставлено за ${price} Soul`);
    closeModal('nftModal');
    await Promise.all([loadMyNfts(), loadMarket(), loadCatalog()]);
  } catch(e) { showToast(e.message || 'Ошибка', true); }
}

async function unlistNft(nftId){
  try {
    await api(`/nft/list/${nftId}`, 'DELETE');
    showToast('Снято с маркета');
    closeModal('nftModal');
    await Promise.all([loadMyNfts(), loadMarket(), loadCatalog()]);
  } catch(e) { showToast(e.message || 'Ошибка', true); }
}

async function openTransferNft(nftId){
  const raw = await Dialog.prompt('Username получателя:', '',
    { title: 'Передать NFT', placeholder: '@user', okText: 'Далее' });
  if (raw == null) return;
  const username = raw.trim().replace(/^@/, '').toLowerCase();
  if (!username) return;
  const ok = await Dialog.confirm(`Передать NFT юзеру @${username}?\n\nКомиссия: 1 Soul.`,
    { title: 'Подтвердить передачу', okText: 'Передать' });
  if (!ok) return;
  try {
    const r = await api('/nft/transfer', 'POST', { nft_id: nftId, to_username: username });
    showToast(`NFT передан @${r.recipient.username}`);
    closeModal('nftModal');
    loadWallet(); loadMyNfts();
  } catch(e) { showToast(e.message || 'Ошибка', true); }
}

// ── Soul transfer ──
function openTransferSoul(){
  document.getElementById('trUser').value = '';
  document.getElementById('trAmount').value = '';
  document.getElementById('trNote').value = '';
  openModal('transferModal');
}
async function doTransferSoul(){
  const u = document.getElementById('trUser').value.trim().toLowerCase();
  const a = +document.getElementById('trAmount').value;
  const n = document.getElementById('trNote').value.trim();
  if (!u || !a || a < 1) { showToast('Заполните username и сумму', true); return; }
  const btn = document.getElementById('trSubmit');
  btn.disabled = true;
  try {
    const r = await api('/soul/transfer', 'POST', { to_username: u, amount: a, note: n || null });
    showToast(`Отправлено @${r.recipient.username} · комиссия ${r.fee}`);
    closeModal('transferModal');
    await loadWallet();
  } catch(e) { showToast(e.message || 'Ошибка перевода', true); }
  btn.disabled = false;
}

function scrollToSection(id){
  const el = document.getElementById(id);
  if (el) el.scrollIntoView({behavior:'smooth', block:'start'});
}

// ── Рендер NFT-арта универсально (preset SVG или emoji) ──
function nftArt(catalog){
  if (catalog.image_kind === 'emoji') {
    const c = safeColor(catalog.bg_color || '#a855f7');  // whitelist hex
    const t = catalog.image_data || '?';
    return `<div style="width:100%;height:100%;border-radius:14px;background:${c};display:flex;align-items:center;justify-content:center;font-size:36px;font-weight:800;color:#fff;text-shadow:0 2px 8px rgba(0,0,0,0.4);">${esc(t)}</div>`;
  }
  return nftSvg(catalog.slug);
}

// ══════════════ INVOICES ══════════════
async function loadInvoices(){
  try {
    const r = await api('/invoice/my');
    const items = r.invoices || [];
    document.getElementById('myInvCount').textContent = items.length ? items.length : '';
    const root = document.getElementById('myInvList');
    if (!items.length) { root.innerHTML = '<div class="my-empty"><i class="fa-solid fa-receipt"></i>Счетов пока нет.<br>Создайте — получите ссылку для оплаты.</div>'; return; }
    root.innerHTML = '<div class="tx-list">' + items.map(i => {
      const url = `${location.origin}/bank/?pay=${i.code}`;
      const status = i.cancelled ? '<span style="color:var(--red);">отменён</span>' : (i.seconds_left <= 0 ? '<span style="color:var(--sub);">истёк</span>' : `<span style="color:var(--green);">активен · ${Math.floor(i.seconds_left/86400)}д ${Math.floor(i.seconds_left%86400/3600)}ч</span>`);
      const codeArg = jsArg(i.code);
      return `<div class="tx-item">
        <div class="tx-icon" style="color:var(--soul);background:rgba(236,72,153,0.12);"><i class="fa-solid fa-receipt"></i></div>
        <div class="tx-body">
          <div class="tx-title">${pricePill(i.amount_soul, 'soul')} ${i.note ? '· ' + esc(i.note) : ''}</div>
          <div class="tx-meta">оплачен ${i.paid_count}× · ${status} · <a href="${esc(url)}" onclick="copyInvLink(event, ${codeArg})" style="color:var(--primary);text-decoration:underline;">копировать ссылку</a></div>
        </div>
        ${!i.cancelled && i.seconds_left > 0 ? `<button class="btn ghost" style="padding:6px 10px;font-size:11px;" onclick="cancelInvoice(${codeArg})">×</button>` : ''}
      </div>`;
    }).join('') + '</div>';
  } catch(e) { console.error('[invoices]', e); }
}
function copyInvLink(ev, code){
  ev.preventDefault();
  const url = `${location.origin}/bank/?pay=${encodeURIComponent(code)}`;
  navigator.clipboard.writeText(url).then(() => showToast('Ссылка скопирована'));
}
async function cancelInvoice(code){
  if (!await Dialog.confirm('Отменить счёт?', { title: 'Отменить счёт', danger: true })) return;
  return withLock('inv-cancel:'+code, async () => {
    try { await api(`/invoice/${code}`, 'DELETE'); showToast('Отменён'); loadInvoices(); }
    catch(e) { showToast(e.message, true); }
  });
}
function openInvoiceCreate(){
  document.getElementById('invcAmount').value = '';
  document.getElementById('invcNote').value = '';
  openModal('invCreateModal');
}
async function doCreateInvoice(){
  const amount = +document.getElementById('invcAmount').value;
  const note = document.getElementById('invcNote').value.trim();
  if (!amount || !Number.isFinite(amount) || amount < 1) { showToast('Введите сумму', true); return; }
  return withLock('inv-create', async () => {
    try {
      const r = await api('/invoice/create', 'POST', { amount_soul: amount, note: note || null });
      showToast(`Счёт создан · ${r.code}`);
      closeModal('invCreateModal');
      await Promise.all([loadInvoices(), loadWallet()]);
      const url = `${location.origin}/bank/?pay=${encodeURIComponent(r.code)}`;
      navigator.clipboard.writeText(url).then(() => showToast('Ссылка скопирована'));
    } catch(e) { showToast(e.message, true); }
  });
}

// Открыть страницу оплаты при ?pay=CODE
async function checkInvoicePayParam(){
  const p = new URLSearchParams(location.search);
  const code = p.get('pay');
  if (!code) return;
  try {
    if (!/^[a-z0-9-]{1,20}$/i.test(code)) { showToast('Невалидный код счёта', true); return; }
    const inv = await api(`/invoice/${encodeURIComponent(code)}`);
    const fee = Math.max(1, Math.ceil(inv.amount_soul * (inv.fee_bps / 10000)));
    const isMine = me && inv.owner.username === me.username;
    const expired = inv.expired || inv.cancelled;
    const cont = document.getElementById('invPayContent');
    cont.innerHTML = `
      <div class="modal-head"><div class="modal-title">Оплата счёта</div><button class="modal-close" onclick="closeModal('invPayModal');history.replaceState(null,'',location.pathname);"><i class="fa-solid fa-xmark"></i></button></div>
      <div class="modal-info">
        <h3>${pricePill(inv.amount_soul, 'soul')}</h3>
        ${inv.note ? `<div class="sub">${esc(inv.note)}</div>` : ''}
      </div>
      <div>
        <div class="modal-row"><span>Получатель</span><b>${inv.owner.is_official ? verifiedBadge() : ''}@${esc(inv.owner.username)}</b></div>
        <div class="modal-row"><span>Сумма счёта</span><span class="v">${pricePill(inv.amount_soul, 'soul')}</span></div>
        <div class="modal-row"><span>Комиссия (5%)</span><span class="v">${pricePill(fee, 'soul')}</span></div>
        <div class="modal-row"><span><b>Итого с вашего баланса</b></span><span class="v"><b>${pricePill(inv.amount_soul + fee, 'soul')}</b></span></div>
        <div class="modal-row"><span>Уже оплачен раз</span><b>${inv.paid_count}</b></div>
      </div>
      <div class="modal-actions">
        <button class="btn ghost" onclick="closeModal('invPayModal');history.replaceState(null,'',location.pathname);">Отмена</button>
        ${expired ? '<button class="btn ghost" disabled>Счёт неактивен</button>' : isMine ? '<button class="btn ghost" disabled>Это ваш счёт</button>' : `<button class="btn primary" onclick="payInvoice(${jsArg(code)})">Оплатить</button>`}
      </div>`;
    openModal('invPayModal');
  } catch(e) { showToast(e.message || 'Счёт не найден', true); }
}
async function payInvoice(code){
  return withLock('pay:'+code, async () => {
    try {
      const r = await api(`/invoice/${encodeURIComponent(code)}/pay`, 'POST');
      showToast(`Оплачено! −${fmtNum(r.amount + r.fee)} Soul`);
      closeModal('invPayModal');
      history.replaceState(null, '', location.pathname);
      loadWallet();
    } catch(e) { showToast(e.message, true); }
  });
}

// ══════════════ USERNAMES ══════════════
async function openUsername(){
  try {
    const r = await api('/username/my');
    const cont = document.getElementById('usernameContent');
    const additional = r.additional || [];
    cont.innerHTML = `
      <div class="modal-head"><div class="modal-title">Мои username</div><button class="modal-close" onclick="closeModal('usernameModal')"><i class="fa-solid fa-xmark"></i></button></div>
      <div class="modal-row"><span>Создано всего (lifetime)</span><b>${r.lifetime_created} / ${r.lifetime_cap}</b></div>
      <div class="modal-row"><span>Сейчас primary</span><b>@${esc(r.primary)}</b></div>
      ${additional.length ? '<div style="margin-top:12px;font-size:11px;color:var(--sub);text-transform:uppercase;font-weight:700;letter-spacing:0.5px;">Дополнительные:</div>' : ''}
      ${additional.map(a => {
        const uArg = jsArg(a.username);
        const priceArg = a.for_sale_price == null ? 'null' : Number(a.for_sale_price);
        return `
        <div class="modal-row">
          <span>@${esc(a.username)}${a.for_sale_price ? ` <span style="color:var(--soul);font-size:11px;">· продаётся за ${Number(a.for_sale_price)}</span>` : ''}</span>
          <span style="display:flex;gap:6px;">
            <button class="btn ghost" style="padding:5px 10px;font-size:11px;" onclick="setUsernamePrimary(${uArg})">Сделать primary</button>
            <button class="btn ghost" style="padding:5px 10px;font-size:11px;" onclick="listUsernameForSale(${uArg}, ${priceArg})">${a.for_sale_price ? 'Снять' : 'Продать'}</button>
          </span>
        </div>`;
      }).join('')}
      ${r.lifetime_created < r.lifetime_cap ? `
        <div class="field" style="margin-top:14px;">
          <label>Создать новый username (100 Soul, осталось ${r.lifetime_cap - r.lifetime_created} раз)</label>
          <input id="unNew" placeholder="например cool-name" autocomplete="off">
        </div>
        <div class="modal-actions">
          <button class="btn ghost" onclick="closeModal('usernameModal')">Закрыть</button>
          <button class="btn primary" onclick="doCreateUsername()">Создать за 100 Soul</button>
        </div>` : '<div style="text-align:center;color:var(--sub);font-size:12px;margin-top:14px;">Лимит создания исчерпан. Дополнительные можно только купить у других.</div><div class="modal-actions"><button class="btn ghost" onclick="closeModal(\'usernameModal\')">Закрыть</button></div>'}
    `;
    openModal('usernameModal');
  } catch(e) { showToast(e.message, true); }
}
async function doCreateUsername(){
  const u = document.getElementById('unNew').value.trim().toLowerCase();
  if (!u) { showToast('Введите username', true); return; }
  try {
    await api('/username/create', 'POST', { username: u });
    showToast(`Создан @${u}`);
    closeModal('usernameModal');
    loadWallet();
  } catch(e) { showToast(e.message, true); }
}
async function setUsernamePrimary(u){
  if (!await Dialog.confirm(`Сделать @${u} основным username?`, { title: 'Сменить основной', okText: 'Сделать основным' })) return;
  try {
    const r = await api('/username/set_primary', 'POST', { username: u });
    showToast(`Теперь @${r.primary}`);
    me.username = r.primary;
    localStorage.setItem('gs_me', JSON.stringify(me));
    closeModal('usernameModal');
  } catch(e) { showToast(e.message, true); }
}
async function listUsernameForSale(u, currentPrice){
  if (currentPrice !== null) {
    if (!await Dialog.confirm(`Снять @${u} с продажи?`, { title: 'Снять', okText: 'Снять' })) return;
    try { await api('/username/list', 'POST', { username: u, price_soul: null }); showToast('Снят'); openUsername(); }
    catch(e) { showToast(e.message, true); }
    return;
  }
  const raw = await Dialog.prompt(`Цена в Soul за @${u}:`, '50',
    { title: 'Выставить на продажу', placeholder: 'число', okText: 'Выставить' });
  if (raw == null) return;
  const price = +raw;
  if (!price || price < 1) return;
  try { await api('/username/list', 'POST', { username: u, price_soul: price }); showToast(`Выставлен за ${price} Soul`); openUsername(); }
  catch(e) { showToast(e.message, true); }
}

// ══════════════ MINT NFT ══════════════
function openMintNft(){
  document.getElementById('mintEmoji').value = '';
  document.getElementById('mintSlug').value = '';
  document.getElementById('mintName').value = '';
  document.getElementById('mintSupply').value = 100;
  document.getElementById('mintAutoBuy').value = 0;
  document.getElementById('mintSellPrice').value = 1;
  document.getElementById('mintBg').value = '#a855f7';
  updateMintPreview();
  updateMintCost();
  openModal('mintModal');
}
function updateMintPreview(){
  const emoji = document.getElementById('mintEmoji').value || '?';
  const bg = document.getElementById('mintBg').value;
  const p = document.getElementById('mintPreview');
  p.textContent = emoji;
  p.style.background = bg;
}
function updateMintCost(){
  const supply = +document.getElementById('mintSupply').value || 100;
  const autoBuy = +document.getElementById('mintAutoBuy').value || 0;
  const price = +document.getElementById('mintSellPrice').value || 1;
  const supplyFee = Math.max(1, Math.round((10000 / supply) ** 1.1));
  const gostCost = 50 + supplyFee;
  const soulPayout = autoBuy * price;
  document.getElementById('mintCostG').innerHTML = `${pricePill(gostCost, 'gost')} <span style="color:var(--sub);font-size:11px;">(50 + ${supplyFee})</span>`;
  document.getElementById('mintPayout').innerHTML = soulPayout > 0 ? pricePill(soulPayout, 'soul') + ' от системы' : '0';
}
async function doMintNft(){
  const body = {
    slug: document.getElementById('mintSlug').value.trim().toLowerCase(),
    name: document.getElementById('mintName').value.trim(),
    description: '',
    supply: +document.getElementById('mintSupply').value,
    image_emoji: document.getElementById('mintEmoji').value.trim(),
    bg_color: document.getElementById('mintBg').value,
    rarity: 'common',
    auto_buy: +document.getElementById('mintAutoBuy').value,
    sell_price_soul: +document.getElementById('mintSellPrice').value,
  };
  if (!body.slug || !body.name || !body.image_emoji) { showToast('Заполните slug, имя и эмодзи', true); return; }
  if (!Number.isInteger(body.supply) || body.supply < 1) { showToast('Тираж: целое число > 0', true); return; }
  if (!Number.isFinite(body.sell_price_soul) || body.sell_price_soul < 0) { showToast('Цена: число ≥ 0', true); return; }
  return withLock('mint:'+body.slug, async () => {
    try {
      const r = await api('/nft/mint', 'POST', body);
      showToast(`NFT создан! −${r.gost_paid} Gost, +${r.soul_received} Soul`);
      closeModal('mintModal');
      await Promise.all([loadWallet(), loadCatalog(), loadMyNfts(), loadMarket()]);
    } catch(e) { showToast(e.message, true); }
  });
}

// ══════════════ SEED PHRASE ══════════════
function showSeedModal(seed){
  document.getElementById('seedDisplay').textContent = seed;
  document.getElementById('seedDisplay').dataset.seed = seed;
  openModal('seedModal');
}
function copySeed(){
  const s = document.getElementById('seedDisplay').dataset.seed;
  navigator.clipboard.writeText(s).then(() => showToast('Скопировано'));
}

// ── WebSocket ──
function connectWS(){
  if (_wsAuthFail) return;
  if (_ws && (_ws.readyState === 0 || _ws.readyState === 1)) return;
  const base = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/api/soc/ws';
  const u = token ? `${base}?token=${encodeURIComponent(token)}` : base;
  try { _ws = new WebSocket(u); } catch(_) { setTimeout(connectWS, _wsReconnectDelay); return; }
  let pingTimer = null;
  _ws.onopen = () => {
    _wsReconnectDelay = 1000;
    clearInterval(pingTimer);
    pingTimer = setInterval(() => { try { _ws.send('ping'); } catch(_) {} }, 25000);
    loadWallet();
  };
  _ws.onmessage = (e) => {
    if (e.data === 'pong') return;
    let m; try { m = JSON.parse(e.data); } catch(_) { return; }
    handleWS(m);
  };
  _ws.onclose = (ev) => {
    clearInterval(pingTimer);
    if (ev && (ev.code === 1008 || ev.code === 4401 || ev.code === 4403)) { _wsAuthFail = true; return; }
    setTimeout(connectWS, _wsReconnectDelay);
    _wsReconnectDelay = Math.min(_wsReconnectDelay * 2, 30000);
  };
  _ws.onerror = () => { try { _ws.close(); } catch(_) {} };
}
function handleWS(m){
  const t = m.type, d = m.data || {};
  if (t === 'wallet.credit') {
    if (d.currency === 'gost' && typeof d.balance === 'number') setBalance('bGost', d.balance);
    if (d.currency === 'soul' && typeof d.balance === 'number') setBalance('bSoul', d.balance);
    const lbl = {register:'welcome', daily:'дейли', post:'за пост', react:'за лайк', comment:'за коммент', follow:'за подписчика', transfer_in:'перевод', nft_sell:'продажа NFT'}[d.source] || d.source;
    const sign = d.delta > 0 ? '+' : '';
    showToast(`${sign}${d.delta} ${d.currency === 'soul' ? 'Soul' : 'Gost'} · ${lbl}`);
    loadWallet();
  } else if (t === 'nft.sold' || t === 'nft.received') {
    loadMarket(); loadMyNfts(); loadCatalog();
    if (t === 'nft.received') showToast(`Вам передан NFT от @${d.from}!`);
  }
}

function showAuth(){
  document.getElementById('authScreen').style.display = 'flex';
  document.getElementById('app').style.display = 'none';
}
function showApp(){
  document.getElementById('authScreen').style.display = 'none';
  document.getElementById('app').style.display = '';
  if (me) document.getElementById('hAvatar').textContent = ini(me.display_name || me.username);
  selectCurrency(_activeCurrency);
}

async function init(){
  if (!token) { showAuth(); return; }
  try {
    const d = await api('/me');
    me = { id: d.id || d.user_id, username: d.username, display_name: d.display_name, is_guest: !!d.is_guest };
    localStorage.setItem('gs_me', JSON.stringify(me));
    if (me.is_guest) { showAuth(); return; }
    showApp();
    await Promise.all([loadWallet(), loadCatalog(), loadMyNfts(), loadMarket(), loadInvoices()]);
    connectWS();
    checkInvoicePayParam();
  } catch(e) {
    console.error('[init]', e);
    if (e.status === 401) { localStorage.removeItem('gs_token'); localStorage.removeItem('gs_me'); }
    showAuth();
  }
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && token) { loadWallet(); loadMarket(); loadMyNfts(); }
});
window.addEventListener('focus', () => { if (token) loadWallet(); });

init();

// ── Реферальная программа ──
async function loadRefBlock(){
  let data;
  try { data = await api('/ref/me'); }
  catch(e) { return; }
  const sec = document.getElementById('refSection');
  if (!sec) return;
  sec.style.display = '';
  const origin = location.origin || 'https://ghostecos.duckdns.org';
  const fullLink = origin + '/?ref=' + encodeURIComponent(data.username);
  document.getElementById('refLinkInp').value = fullLink;
  const stats = document.getElementById('refStats');
  if (stats) stats.textContent = `${data.total_invited} · +${data.total_earned_gost} Gost`;
  // Список приглашённых
  const list = document.getElementById('refInvitedList');
  if (data.invited && data.invited.length) {
    list.innerHTML = `<div style="font-size:10px;color:var(--muted);font-weight:700;text-transform:uppercase;letter-spacing:0.05em;margin-bottom:6px;">Кого ты привёл (${data.total_invited})</div>` +
      data.invited.slice(0, 5).map(u =>
        `<div style="display:flex;align-items:center;gap:8px;padding:6px 0;border-bottom:1px solid rgba(255,255,255,0.05);">
           <div style="width:24px;height:24px;border-radius:50%;background:linear-gradient(135deg,var(--primary),var(--primary2));display:flex;align-items:center;justify-content:center;color:#fff;font-size:11px;font-weight:700;">${(u.display_name||u.username||'?')[0].toUpperCase()}</div>
           <div style="flex:1;font-size:12px;">${escape_(u.display_name || u.username)}</div>
           <div style="font-size:10px;color:var(--muted);">@${escape_(u.username)}</div>
         </div>`
      ).join('') +
      (data.total_invited > 5 ? `<div style="font-size:11px;color:var(--muted);text-align:center;margin-top:6px;">+ ещё ${data.total_invited - 5}</div>` : '');
  } else {
    list.innerHTML = '';
  }
}

function escape_(s) {
  return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

async function copyRefLink(){
  const inp = document.getElementById('refLinkInp');
  if (!inp || !inp.value) return;
  try {
    await navigator.clipboard.writeText(inp.value);
    const btn = document.getElementById('refCopyBtn');
    const old = btn.innerHTML;
    btn.innerHTML = '<i class="fa-solid fa-check"></i>';
    setTimeout(() => { btn.innerHTML = old; }, 1500);
    showToast('Ссылка скопирована');
  } catch(_) {
    inp.select(); document.execCommand('copy');
    showToast('Ссылка скопирована');
  }
}

async function shareRefLink(){
  const link = document.getElementById('refLinkInp').value;
  if (!link) return;
  const text = 'Заходи в GhostChat — мессенджер где сервер не видит твои сообщения. Получишь +30 Gost: ' + link;
  if (navigator.share) {
    try { await navigator.share({title:'GhostChat', text, url: link}); return; } catch(_) {}
  }
  // Fallback: копируем
  try {
    await navigator.clipboard.writeText(text);
    showToast('Текст скопирован');
  } catch(_) { showToast('Скопируйте ссылку вручную', true); }
}