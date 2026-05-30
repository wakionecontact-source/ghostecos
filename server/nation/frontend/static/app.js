/* ════════════════════════════════════════════════════════════
   GhostNation — основай своё государство на спутниковой карте
   Личная песочница, всё хранится в localStorage. Без бэкенда.
   ════════════════════════════════════════════════════════════ */

const STORE_KEY = 'ghostnation:v1';

const FLAG_COLORS = [
  '#D97757', '#E0245E', '#F5A623', '#F8E71C', '#7ED321',
  '#50E3C2', '#4A90E2', '#9013FE', '#FFFFFF', '#15C26B',
];

/* ── default save ── */
function freshState() {
  return {
    name: '',
    color: FLAG_COLORS[0],
    border: null,          // [[lat,lng], ...] | null
    buildings: [],         // [{type:'house'|'tree', lat, lng}]
    roads: [],             // [ [[lat,lng], ...], ... ]
    view: { lat: 55.7512, lng: 37.6184, zoom: 12 }, // Москва — есть что застраивать
  };
}

let state = load();

function load() {
  try {
    const raw = localStorage.getItem(STORE_KEY);
    if (raw) return Object.assign(freshState(), JSON.parse(raw));
  } catch (e) { console.warn('load failed', e); }
  return freshState();
}
function save() {
  try { localStorage.setItem(STORE_KEY, JSON.stringify(state)); }
  catch (e) { console.warn('save failed', e); }
}

/* ════════════════ ICONS ════════════════ */
const ICON_NAMES = ['borders', 'house', 'road', 'tree', 'trash', 'flag', 'target'];
const ICONS = {};
async function loadIcons() {
  await Promise.all(ICON_NAMES.map(async n => {
    try { ICONS[n] = await (await fetch(`icons/${n}.svg`)).text(); }
    catch (e) { ICONS[n] = ''; }
  }));
}

/* ════════════════ MAP ════════════════ */
let map, territory = null;
let layers = {}, currentLayer = 'esri';

function initMap() {
  map = L.map('map', { zoomControl: false, attributionControl: true, worldCopyJump: true })
        .setView([state.view.lat, state.view.lng], state.view.zoom);

  L.control.zoom({ position: 'topright' }).addTo(map);

  layers.esri = L.tileLayer(
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    { maxZoom: 19, attribution: 'Esri · GhostNation' });
  layers.google = L.tileLayer(
    'https://mt{s}.google.com/vt/lyrs=s&x={x}&y={y}&z={z}',
    { maxZoom: 20, subdomains: ['0', '1', '2', '3'], attribution: 'Google · GhostNation' });

  layers[currentLayer].addTo(map);

  map.on('moveend', () => {
    const c = map.getCenter();
    state.view = { lat: c.lat, lng: c.lng, zoom: map.getZoom() };
    save();
  });
  map.on('click', onMapClick);
  map.on('mousemove', onMapMove);
}

/* ════════════════ TOOLS ════════════════ */
let activeTool = null;   // null | 'borders' | 'house' | 'road' | 'tree' | 'erase'

function setTool(tool) {
  if (draw.active) cancelDraw();
  activeTool = (activeTool === tool) ? null : tool;

  document.querySelectorAll('.tool[data-tool]').forEach(b =>
    b.classList.toggle('active', b.dataset.tool === activeTool));

  const mapEl = document.getElementById('map');
  mapEl.classList.toggle('drawing', activeTool === 'house' || activeTool === 'tree');
  mapEl.classList.toggle('erasing', activeTool === 'erase');

  if (activeTool === 'borders') startDraw('borders');
  else if (activeTool === 'road') startDraw('road');
}

/* ════════════════ DRAW ENGINE (borders + roads) ════════════════ */
const draw = { active: false, mode: null, points: [], preview: null, rubber: null, handles: [] };

function startDraw(mode) {
  draw.active = true;
  draw.mode = mode;
  draw.points = [];
  draw.handles = [];
  draw.preview = (mode === 'borders')
    ? L.polygon([], { color: state.color, weight: 2.5, fillColor: state.color, fillOpacity: .15, dashArray: '6 5' }).addTo(map)
    : L.polyline([], { color: '#fff', weight: 4, dashArray: '6 6' }).addTo(map);
  draw.rubber = L.polyline([], { color: state.color, weight: 1.6, opacity: .7, dashArray: '4 5', interactive: false }).addTo(map);
  document.getElementById('map').classList.add('drawing');
  openDrawBar();
  updateDrawHint();
}

function addVertex(latlng) {
  draw.points.push(latlng);
  const h = L.marker(latlng, {
    icon: L.divIcon({ className: '', html: '<div class="vertex-dot"></div>', iconSize: [12, 12] }),
    interactive: false, keyboard: false,
  }).addTo(map);
  draw.handles.push(h);
  draw.preview.setLatLngs(draw.points);
  updateDrawHint();
}

function onMapMove(e) {
  if (!draw.active || !draw.points.length) return;
  draw.rubber.setLatLngs([draw.points[draw.points.length - 1], e.latlng]);
}

function undoVertex() {
  if (!draw.points.length) return;
  draw.points.pop();
  const h = draw.handles.pop();
  if (h) map.removeLayer(h);
  draw.preview.setLatLngs(draw.points);
  if (!draw.points.length) draw.rubber.setLatLngs([]);
  updateDrawHint();
}

function finishDraw() {
  const min = draw.mode === 'borders' ? 3 : 2;
  if (draw.points.length < min) return;
  const pts = draw.points.map(p => [p.lat, p.lng]);
  if (draw.mode === 'borders') { state.border = pts; renderTerritory(); }
  else { state.roads.push(pts); renderRoads(); }
  save();
  clearDraw();
  setToolIdle();
  updateStats();
}

function cancelDraw() { clearDraw(); }

function clearDraw() {
  if (draw.preview) map.removeLayer(draw.preview);
  if (draw.rubber) map.removeLayer(draw.rubber);
  draw.handles.forEach(h => map.removeLayer(h));
  Object.assign(draw, { active: false, mode: null, points: [], preview: null, rubber: null, handles: [] });
  document.getElementById('draw-bar').classList.add('hidden');
  document.getElementById('map').classList.remove('drawing');
}

function setToolIdle() {
  activeTool = null;
  document.querySelectorAll('.tool[data-tool]').forEach(b => b.classList.remove('active'));
  document.getElementById('map').classList.remove('drawing', 'erasing');
}

function openDrawBar() {
  document.getElementById('draw-bar').classList.remove('hidden');
}

function updateDrawHint() {
  const hint = document.getElementById('draw-hint');
  const doneBtn = document.getElementById('draw-done');
  const n = draw.points.length;
  if (draw.mode === 'borders') {
    const ok = n >= 3;
    doneBtn.disabled = !ok;
    let extra = '';
    if (ok) extra = ' · ~' + fmtArea(geodesicArea(draw.points));
    hint.textContent = `Граница: ${n} ${plural(n, 'точка', 'точки', 'точек')}${extra}`;
  } else {
    const ok = n >= 2;
    doneBtn.disabled = !ok;
    let extra = '';
    if (ok) extra = ' · ' + fmtLen(pathLength(draw.points));
    hint.textContent = `Дорога: ${n} ${plural(n, 'точка', 'точки', 'точек')}${extra}`;
  }
}

/* ════════════════ MAP CLICK ROUTING ════════════════ */
function onMapClick(e) {
  if (draw.active) { addVertex(e.latlng); return; }
  if (activeTool === 'house' || activeTool === 'tree') {
    state.buildings.push({ type: activeTool, lat: e.latlng.lat, lng: e.latlng.lng });
    save();
    renderBuildings();
    updateStats();
  }
  // 'erase' handled by per-object click handlers
}

/* ════════════════ RENDER ════════════════ */
let buildLayer, roadLayer;

function renderTerritory() {
  if (territory) { map.removeLayer(territory); territory = null; }
  if (!state.border) return;
  territory = L.polygon(state.border, {
    color: state.color, weight: 2.5, opacity: .95,
    fillColor: state.color, fillOpacity: .18,
  }).addTo(map);
  territory.on('click', e => {
    if (activeTool !== 'erase') return;
    L.DomEvent.stop(e);
    state.border = null; save(); renderTerritory(); updateStats();
  });
}

function renderBuildings() {
  buildLayer.clearLayers();
  state.buildings.forEach(b => {
    const cls = b.type === 'tree' ? 'tree' : 'house';
    const m = L.marker([b.lat, b.lng], {
      icon: L.divIcon({
        className: '', iconSize: [30, 30], iconAnchor: [15, 15],
        html: `<div class="build-marker ${cls}">${ICONS[b.type] || ''}</div>`,
      }),
    }).addTo(buildLayer);
    m.on('click', e => {
      if (activeTool !== 'erase') return;
      L.DomEvent.stop(e);
      state.buildings = state.buildings.filter(x => x !== b);
      save(); renderBuildings(); updateStats();
    });
  });
}

function renderRoads() {
  roadLayer.clearLayers();
  state.roads.forEach(r => {
    const casing = L.polyline(r, { color: '#000', weight: 6, opacity: .55 }).addTo(roadLayer);
    const surf = L.polyline(r, { color: '#fff', weight: 3, opacity: .95 }).addTo(roadLayer);
    const erase = e => {
      if (activeTool !== 'erase') return;
      L.DomEvent.stop(e);
      state.roads = state.roads.filter(x => x !== r);
      save(); renderRoads(); updateStats();
    };
    casing.on('click', erase); surf.on('click', erase);
  });
}

function renderAll() {
  renderTerritory();
  renderBuildings();
  renderRoads();
  updateStats();
  document.getElementById('state-name').value = state.name;
  paintFlag();
}

/* ════════════════ STATS ════════════════ */
function updateStats() {
  const area = state.border ? geodesicArea(state.border.map(p => L.latLng(p[0], p[1]))) : 0;
  document.getElementById('stat-area').textContent = fmtArea(area);
  const n = state.buildings.length + state.roads.length;
  document.getElementById('stat-builds').textContent =
    `${n} ${plural(n, 'постройка', 'постройки', 'построек')}`;
}

/* ════════════════ FLAG / NAME ════════════════ */
function paintFlag() {
  const chip = document.getElementById('flag');
  chip.style.background = state.color;
  chip.innerHTML = ICONS.flag || '';
  chip.style.color = pickContrast(state.color);
}

function buildPalette() {
  const pal = document.getElementById('palette');
  pal.innerHTML = '';
  FLAG_COLORS.forEach(c => {
    const sw = document.createElement('button');
    sw.className = 'swatch' + (c === state.color ? ' active' : '');
    sw.style.background = c;
    sw.style.color = c;
    sw.onclick = () => {
      state.color = c; save();
      paintFlag();
      if (territory) territory.setStyle({ color: c, fillColor: c });
      buildPalette();
      pal.classList.add('hidden');
    };
    pal.appendChild(sw);
  });
}

/* ════════════════ GEO MATH ════════════════ */
function geodesicArea(latlngs) {       // m², spherical polygon
  const R = 6378137, d2r = Math.PI / 180, n = latlngs.length;
  if (n < 3) return 0;
  let a = 0;
  for (let i = 0; i < n; i++) {
    const p1 = latlngs[i], p2 = latlngs[(i + 1) % n];
    a += (p2.lng - p1.lng) * d2r *
         (2 + Math.sin(p1.lat * d2r) + Math.sin(p2.lat * d2r));
  }
  return Math.abs(a * R * R / 2);
}
function pathLength(latlngs) {          // metres
  let d = 0;
  for (let i = 1; i < latlngs.length; i++) d += map.distance(latlngs[i - 1], latlngs[i]);
  return d;
}

/* ════════════════ FORMAT ════════════════ */
function fmtArea(m2) {
  if (m2 <= 0) return '0 км²';
  if (m2 < 1e6) return Math.round(m2).toLocaleString('ru-RU') + ' м²';
  const km = m2 / 1e6;
  return km.toLocaleString('ru-RU', { maximumFractionDigits: km < 10 ? 2 : km < 100 ? 1 : 0 }) + ' км²';
}
function fmtLen(m) {
  if (m < 1000) return Math.round(m) + ' м';
  return (m / 1000).toLocaleString('ru-RU', { maximumFractionDigits: 2 }) + ' км';
}
function plural(n, one, few, many) {
  const m10 = n % 10, m100 = n % 100;
  if (m10 === 1 && m100 !== 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20)) return few;
  return many;
}
function pickContrast(hex) {
  const c = hex.replace('#', '');
  const r = parseInt(c.substr(0, 2), 16), g = parseInt(c.substr(2, 2), 16), b = parseInt(c.substr(4, 2), 16);
  return (r * 299 + g * 587 + b * 114) / 1000 > 150 ? '#1a0f0a' : '#fff';
}

/* ════════════════ LOCATE ════════════════ */
function locate() {
  if (state.border && state.border.length) {
    map.fitBounds(L.polygon(state.border).getBounds(), { padding: [60, 60] });
  } else if (state.buildings.length) {
    map.fitBounds(L.latLngBounds(state.buildings.map(b => [b.lat, b.lng])), { padding: [80, 80], maxZoom: 16 });
  }
}

/* ════════════════ WIRING ════════════════ */
function wire() {
  document.querySelectorAll('.tool[data-tool]').forEach(b => {
    const t = b.dataset.tool;
    b.innerHTML = ICONS[t === 'erase' ? 'trash' : t] || '';
    b.onclick = () => setTool(t);
  });
  document.getElementById('locate').innerHTML = ICONS.target || '';
  document.getElementById('locate').onclick = locate;

  document.getElementById('draw-undo').onclick = undoVertex;
  document.getElementById('draw-done').onclick = finishDraw;
  document.getElementById('draw-cancel').onclick = () => { cancelDraw(); setToolIdle(); };

  const nameEl = document.getElementById('state-name');
  nameEl.value = state.name;
  nameEl.oninput = () => { state.name = nameEl.value.trim(); save(); };

  const chip = document.getElementById('flag');
  chip.onclick = () => document.getElementById('palette').classList.toggle('hidden');

  document.querySelectorAll('.layer').forEach(b => {
    b.onclick = () => {
      const id = b.dataset.layer;
      if (id === currentLayer) return;
      map.removeLayer(layers[currentLayer]);
      layers[id].addTo(map);
      currentLayer = id;
      document.querySelectorAll('.layer').forEach(x => x.classList.toggle('active', x === b));
    };
  });

  document.addEventListener('keydown', e => {
    if (e.key === 'Enter' && draw.active) finishDraw();
    else if (e.key === 'Escape') {
      if (draw.active) { cancelDraw(); setToolIdle(); }
      else document.getElementById('palette').classList.add('hidden');
    } else if (e.key === 'Backspace' && draw.active) { e.preventDefault(); undoVertex(); }
  });
}

/* ════════════════ BOOT ════════════════ */
(async function boot() {
  if (typeof L === 'undefined') {
    document.body.insertAdjacentHTML('beforeend',
      '<div style="position:fixed;inset:0;display:grid;place-items:center;background:#000;color:#fff;font:16px sans-serif;text-align:center;padding:24px">Не удалось загрузить Leaflet с CDN.<br>Проверь интернет/туннель и обнови страницу.</div>');
    return;
  }
  await loadIcons();
  initMap();
  buildLayer = L.layerGroup().addTo(map);
  roadLayer = L.layerGroup().addTo(map);
  buildPalette();
  wire();
  renderAll();
})();
