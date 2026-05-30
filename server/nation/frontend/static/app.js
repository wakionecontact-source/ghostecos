/* ════════════════════════════════════════════════════════════
   GhostNation — основай своё государство на спутниковой карте
   Личная песочница. Автосейв в localStorage + экспорт/импорт файла.
   Постройки — footprint'ы на земле (фикс. размер в метрах).
   ════════════════════════════════════════════════════════════ */

const STORE_KEY = 'ghostnation:v1';

const FLAG_COLORS = [
  '#D97757', '#E0245E', '#F5A623', '#F8E71C', '#7ED321',
  '#50E3C2', '#4A90E2', '#9013FE', '#FFFFFF', '#15C26B',
];

/* footprint-размеры в метрах — одинаковые для всех объектов своего типа */
const SIZE = {
  house: { w: 13, h: 10 },   // жилой — зелёная крыша
  shop:  { w: 13, h: 10 },   // магазин — синяя крыша
  tree:  { r: 3.5 },         // крона
};
const ROOF = {
  house: { fill: '#36b24a', edge: '#0b2c16' },
  shop:  { fill: '#2E7FE0', edge: '#0a1f3a' },
};
const SNAP_PX = 14;          // радиус примагничивания дорог, пиксели

/* ── default save ── */
function freshState() {
  return {
    name: '',
    color: FLAG_COLORS[0],
    border: null,          // [[lat,lng], ...] | null
    buildings: [],         // [{type:'house'|'shop'|'tree', lat, lng}]
    roads: [],             // [ [[lat,lng], ...], ... ]
    rails: [],             // [ [[lat,lng], ...], ... ]
    view: { lat: 55.7512, lng: 37.6184, zoom: 12 },
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
const ICON_NAMES = ['borders', 'house', 'shop', 'road', 'rail', 'tree', 'trash', 'flag', 'target', 'download', 'upload'];
const ICONS = {};
async function loadIcons() {
  await Promise.all(ICON_NAMES.map(async n => {
    try { ICONS[n] = await (await fetch(`icons/${n}.svg`)).text(); }
    catch (e) { ICONS[n] = ''; }
  }));
}

/* ════════════════ MAP ════════════════ */
let map, territory = null;
let buildLayer, roadLayer, railLayer;
let layers = {}, currentLayer = 'esri';

function initMap() {
  map = L.map('map', { zoomControl: false, attributionControl: true, worldCopyJump: true })
        .setView([state.view.lat, state.view.lng], state.view.zoom);

  // panes fix draw order independent of insertion: territory < lines < builds < (markers=600)
  [['pane-territory', 410], ['pane-lines', 420], ['pane-builds', 430]].forEach(([n, z]) => {
    map.createPane(n); map.getPane(n).style.zIndex = z;
  });

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
let activeTool = null;   // null | borders | house | shop | road | rail | tree | erase

function setTool(tool) {
  if (draw.active) cancelDraw();
  activeTool = (activeTool === tool) ? null : tool;

  document.querySelectorAll('.tool[data-tool]').forEach(b =>
    b.classList.toggle('active', b.dataset.tool === activeTool));

  const mapEl = document.getElementById('map');
  mapEl.classList.toggle('drawing', ['house', 'shop', 'tree'].includes(activeTool));
  mapEl.classList.toggle('erasing', activeTool === 'erase');

  if (activeTool === 'borders') startDraw('borders');
  else if (activeTool === 'road') startDraw('road');
  else if (activeTool === 'rail') startDraw('rail');
}

function setToolIdle() {
  activeTool = null;
  document.querySelectorAll('.tool[data-tool]').forEach(b => b.classList.remove('active'));
  document.getElementById('map').classList.remove('drawing', 'erasing');
}

/* ════════════════ DRAW ENGINE (borders + road + rail) ════════════════ */
const draw = { active: false, mode: null, points: [], preview: null, rubber: null, handles: [] };

function startDraw(mode) {
  draw.active = true;
  draw.mode = mode;
  draw.points = [];
  draw.handles = [];
  if (mode === 'borders') {
    draw.preview = L.polygon([], { pane: 'pane-territory', color: state.color, weight: 2.5, fillColor: state.color, fillOpacity: .15, dashArray: '6 5' }).addTo(map);
  } else if (mode === 'road') {
    draw.preview = L.polyline([], { pane: 'pane-lines', color: '#fff', weight: 4, dashArray: '6 6' }).addTo(map);
  } else { // rail
    draw.preview = L.polyline([], { pane: 'pane-lines', color: '#d0d0d0', weight: 4, dashArray: '3 6' }).addTo(map);
  }
  draw.rubber = L.polyline([], { pane: 'pane-lines', color: state.color, weight: 1.6, opacity: .7, dashArray: '4 5', interactive: false }).addTo(map);
  document.getElementById('map').classList.add('drawing');
  document.getElementById('draw-bar').classList.remove('hidden');
  updateDrawHint();
}

function addVertex(latlng) {
  let snapped = false;
  if (draw.mode === 'road' || draw.mode === 'rail') {
    const s = snapPoint(latlng);
    if (s) { latlng = s; snapped = true; }
  }
  draw.points.push(latlng);
  const h = L.marker(latlng, {
    pane: 'markerPane',
    icon: L.divIcon({ className: '', html: `<div class="vertex-dot${snapped ? ' snapped' : ''}"></div>`, iconSize: [12, 12], iconAnchor: [6, 6] }),
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
  else if (draw.mode === 'road') { state.roads.push(pts); renderRoads(); }
  else { state.rails.push(pts); renderRails(); }
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

function updateDrawHint() {
  const hint = document.getElementById('draw-hint');
  const doneBtn = document.getElementById('draw-done');
  const n = draw.points.length;
  if (draw.mode === 'borders') {
    const ok = n >= 3;
    doneBtn.disabled = !ok;
    hint.textContent = `Граница: ${n} ${plural(n, 'точка', 'точки', 'точек')}` + (ok ? ' · ~' + fmtArea(geodesicArea(draw.points)) : '');
  } else {
    const ok = n >= 2;
    const label = draw.mode === 'rail' ? 'Жд' : 'Дорога';
    doneBtn.disabled = !ok;
    hint.textContent = `${label}: ${n} ${plural(n, 'точка', 'точки', 'точек')}` + (ok ? ' · ' + fmtLen(pathLength(draw.points)) : '');
  }
}

/* ════════════════ SNAP (join roads/rails) ════════════════ */
function snapPoint(latlng) {
  const p = map.latLngToLayerPoint(latlng);
  let best = null, bestD = SNAP_PX;
  const lines = state.roads.concat(state.rails);
  for (const line of lines) {
    for (let i = 0; i < line.length; i++) {
      const v = map.latLngToLayerPoint(L.latLng(line[i][0], line[i][1]));
      const dv = p.distanceTo(v);
      if (dv < bestD) { bestD = dv; best = L.latLng(line[i][0], line[i][1]); } // exact vertex, no round-trip drift
      if (i > 0) {
        const a = map.latLngToLayerPoint(L.latLng(line[i - 1][0], line[i - 1][1]));
        const proj = projectOnSeg(p, a, v);
        const dp = p.distanceTo(proj);
        if (dp < bestD) { bestD = dp; best = map.layerPointToLatLng(proj); }
      }
    }
  }
  return best;
}
function projectOnSeg(p, a, b) {
  const dx = b.x - a.x, dy = b.y - a.y;
  const len2 = dx * dx + dy * dy;
  if (len2 === 0) return a;
  let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2;
  t = Math.max(0, Math.min(1, t));
  return L.point(a.x + t * dx, a.y + t * dy);
}

/* ════════════════ MAP CLICK ROUTING ════════════════ */
function onMapClick(e) {
  if (draw.active) { addVertex(e.latlng); return; }
  if (['house', 'shop', 'tree'].includes(activeTool)) {
    state.buildings.push({ type: activeTool, lat: e.latlng.lat, lng: e.latlng.lng });
    save();
    renderBuildings();
    updateStats();
  }
}

/* ════════════════ RENDER ════════════════ */
function renderTerritory() {
  if (territory) { map.removeLayer(territory); territory = null; }
  if (!state.border) return;
  territory = L.polygon(state.border, {
    pane: 'pane-territory',
    color: state.color, weight: 2.5, opacity: .95,
    fillColor: state.color, fillOpacity: .18,
  }).addTo(map);
  territory.on('click', e => {
    if (activeTool !== 'erase') return;
    L.DomEvent.stop(e);
    state.border = null; save(); renderTerritory(); updateStats();
  });
}

/* metre-offsets around a lat/lng */
function metresToDeg(lat, wM, hM) {
  return {
    dLat: (hM / 2) / 111320,
    dLng: (wM / 2) / (111320 * Math.cos(lat * Math.PI / 180)),
  };
}

function drawHouse(b) {                 // house or shop — roof seen from above
  const s = SIZE[b.type], roof = ROOF[b.type];
  const { dLat, dLng } = metresToDeg(b.lat, s.w, s.h);
  const corners = [
    [b.lat - dLat, b.lng - dLng], [b.lat - dLat, b.lng + dLng],
    [b.lat + dLat, b.lng + dLng], [b.lat + dLat, b.lng - dLng],
  ];
  const body = L.polygon(corners, { pane: 'pane-builds', color: roof.edge, weight: 1, fillColor: roof.fill, fillOpacity: .95 }).addTo(buildLayer);
  const ridge = L.polyline([[b.lat, b.lng - dLng], [b.lat, b.lng + dLng]],
    { pane: 'pane-builds', color: '#ffffff', opacity: .5, weight: 1.4 }).addTo(buildLayer);
  [body, ridge].forEach(l => l.on('click', e => eraseHit(e, () => removeBuilding(b))));
}

function drawTree(b) {
  const c = L.circle([b.lat, b.lng], { pane: 'pane-builds', radius: SIZE.tree.r, color: '#16551f', weight: 1, fillColor: '#2f9a44', fillOpacity: .9 }).addTo(buildLayer);
  c.on('click', e => eraseHit(e, () => removeBuilding(b)));
}

function renderBuildings() {
  buildLayer.clearLayers();
  state.buildings.forEach(b => (b.type === 'tree' ? drawTree(b) : drawHouse(b)));
}

function renderRoads() {
  roadLayer.clearLayers();
  state.roads.forEach(r => {
    const casing = L.polyline(r, { pane: 'pane-lines', color: '#000', weight: 6, opacity: .55 }).addTo(roadLayer);
    const surf = L.polyline(r, { pane: 'pane-lines', color: '#fff', weight: 3, opacity: .95 }).addTo(roadLayer);
    [casing, surf].forEach(l => l.on('click', e => eraseHit(e, () => removeLine('roads', r))));
  });
}

function renderRails() {
  railLayer.clearLayers();
  state.rails.forEach(r => {
    const bed = L.polyline(r, { pane: 'pane-lines', color: '#2b2b2b', weight: 6, opacity: .9 }).addTo(railLayer);
    const ties = L.polyline(r, { pane: 'pane-lines', color: '#e9e9e9', weight: 6, opacity: .85, dashArray: '2 7' }).addTo(railLayer);
    const rail = L.polyline(r, { pane: 'pane-lines', color: '#9a9a9a', weight: 1.4, opacity: .95 }).addTo(railLayer);
    [bed, ties, rail].forEach(l => l.on('click', e => eraseHit(e, () => removeLine('rails', r))));
  });
}

function eraseHit(e, fn) {
  if (activeTool !== 'erase') return;
  L.DomEvent.stop(e);
  fn();
}
function removeBuilding(b) {
  state.buildings = state.buildings.filter(x => x !== b);
  save(); renderBuildings(); updateStats();
}
function removeLine(key, r) {
  state[key] = state[key].filter(x => x !== r);
  save(); (key === 'roads' ? renderRoads : renderRails)(); updateStats();
}

function renderAll() {
  renderTerritory();
  renderRoads();
  renderRails();
  renderBuildings();
  updateStats();
  document.getElementById('state-name').value = state.name;
  paintFlag();
}

/* ════════════════ STATS ════════════════ */
function updateStats() {
  const area = state.border ? geodesicArea(state.border.map(p => L.latLng(p[0], p[1]))) : 0;
  document.getElementById('stat-area').textContent = fmtArea(area);
  const n = state.buildings.length + state.roads.length + state.rails.length;
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
    sw.style.background = c; sw.style.color = c;
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
    a += (p2.lng - p1.lng) * d2r * (2 + Math.sin(p1.lat * d2r) + Math.sin(p2.lat * d2r));
  }
  return Math.abs(a * R * R / 2);
}
function pathLength(latlngs) {
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
    map.fitBounds(L.latLngBounds(state.buildings.map(b => [b.lat, b.lng])), { padding: [80, 80], maxZoom: 17 });
  }
}

/* ════════════════ SAVE / LOAD FILE ════════════════ */
function exportFile() {
  const blob = new Blob([JSON.stringify(state, null, 2)], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = (state.name || 'ghostnation').replace(/[^\wа-яё \-]/gi, '').trim() + '.json';
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  flash('Сохранено в файл');
}
function importFile(file) {
  const r = new FileReader();
  r.onload = () => {
    try {
      const obj = JSON.parse(r.result);
      state = Object.assign(freshState(), obj);
      save();
      document.getElementById('state-name').value = state.name;
      buildPalette();
      renderAll();
      locate();
      flash('Государство загружено');
    } catch (e) { flash('Не удалось прочитать файл', true); }
  };
  r.readAsText(file);
}
let flashTimer = null;
function flash(msg, bad) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.style.color = bad ? '#E0245E' : '';
  t.classList.remove('hidden');
  clearTimeout(flashTimer);
  flashTimer = setTimeout(() => t.classList.add('hidden'), 1800);
}

/* ════════════════ WIRING ════════════════ */
function wire() {
  document.querySelectorAll('.tool[data-tool]').forEach(b => {
    const t = b.dataset.tool;
    b.innerHTML = ICONS[t === 'erase' ? 'trash' : t] || '';
    b.onclick = () => setTool(t);
  });
  document.querySelector('[data-action="save"]').innerHTML = ICONS.download || '';
  document.querySelector('[data-action="save"]').onclick = exportFile;
  document.querySelector('[data-action="load"]').innerHTML = ICONS.upload || '';
  document.querySelector('[data-action="load"]').onclick = () => document.getElementById('import-file').click();
  document.getElementById('import-file').onchange = e => { if (e.target.files[0]) importFile(e.target.files[0]); e.target.value = ''; };

  document.getElementById('locate').innerHTML = ICONS.target || '';
  document.getElementById('locate').onclick = locate;

  document.getElementById('draw-undo').onclick = undoVertex;
  document.getElementById('draw-done').onclick = finishDraw;
  document.getElementById('draw-cancel').onclick = () => { cancelDraw(); setToolIdle(); };

  const nameEl = document.getElementById('state-name');
  nameEl.value = state.name;
  nameEl.oninput = () => { state.name = nameEl.value.trim(); save(); };

  document.getElementById('flag').onclick = () => document.getElementById('palette').classList.toggle('hidden');

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
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); exportFile(); return; }
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
  roadLayer = L.layerGroup().addTo(map);
  railLayer = L.layerGroup().addTo(map);
  buildLayer = L.layerGroup().addTo(map);
  buildPalette();
  wire();
  renderAll();
})();
