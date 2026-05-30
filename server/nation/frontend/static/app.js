/* ════════════════════════════════════════════════════════════
   GhostNation — основай своё государство на спутниковой карте
   Личная песочница. Автосейв localStorage + экспорт/импорт файла.
   ════════════════════════════════════════════════════════════ */

const STORE_KEY = 'ghostnation:v1';
const FLAG_COLORS = ['#D97757', '#E0245E', '#F5A623', '#F8E71C', '#7ED321', '#50E3C2', '#4A90E2', '#9013FE', '#FFFFFF', '#15C26B'];
const DEF = { house: { w: 13, h: 10 }, shop: { w: 13, h: 10 }, tree: { r: 3.5 } };
const ROOF = { house: { fill: '#36b24a', edge: '#0b2c16' }, shop: { fill: '#2E7FE0' } };
const LINE_M = { road: 7, rail: 7, path: 1 };   // ширина на земле, метры
const SNAP_PX = 14;
const PORCH = '#ffce86';
const PORCH_DEPTH = 1.8, BUILD_GAP = 1.5;        // крыльцо считается частью здания
const SIDEWALK_OFF = LINE_M.road / 2 + 1;        // тротуар вдоль дороги (от центра)

const clampWH = v => Math.min(100, Math.max(1, v));
const clampR  = v => Math.min(50, Math.max(1, v));
const rand    = (a, b) => a + Math.random() * (b - a);
const randInt = n => Math.floor(Math.random() * n);

function freshState() {
  return { name: '', color: FLAG_COLORS[0], border: null, buildings: [], roads: [], rails: [], paths: [], view: { lat: 55.7512, lng: 37.6184, zoom: 12 } };
}
let state = load();
function load() { try { const r = localStorage.getItem(STORE_KEY); if (r) return Object.assign(freshState(), JSON.parse(r)); } catch (e) { console.warn(e); } return freshState(); }
function save() { try { localStorage.setItem(STORE_KEY, JSON.stringify(state)); } catch (e) { console.warn(e); } }

/* ════════════════ UNDO ════════════════ */
let undoStack = [];
function pushUndo() { undoStack.push(JSON.stringify(state)); if (undoStack.length > 60) undoStack.shift(); updateUndoBtn(); }
function undo() {
  if (!undoStack.length) return;
  state = Object.assign(freshState(), JSON.parse(undoStack.pop()));
  save(); deselect(); clearHover();
  document.getElementById('state-name').value = state.name; buildPalette(); renderAll();
  updateUndoBtn();
}
function updateUndoBtn() { const b = document.querySelector('[data-action="undo"]'); if (b) b.disabled = undoStack.length === 0; }

/* ════════════════ ICONS ════════════════ */
const ICON_NAMES = ['borders', 'house', 'shop', 'road', 'rail', 'path', 'tree', 'select', 'trash', 'flag', 'target', 'download', 'upload', 'undo'];
const ICONS = {};
async function loadIcons() { await Promise.all(ICON_NAMES.map(async n => { try { ICONS[n] = await (await fetch(`icons/${n}.svg`)).text(); } catch (e) { ICONS[n] = ''; } })); }

/* ════════════════ GEO HELPERS ════════════════ */
const MPD_LAT = 111320;
const mPerDegLng = lat => 111320 * Math.cos(lat * Math.PI / 180);
const offset = (lat, lng, eM, nM) => [lat + nM / MPD_LAT, lng + eM / mPerDegLng(lat)];
const mpp = () => 40075016.686 * Math.cos(map.getCenter().lat * Math.PI / 180) / Math.pow(2, map.getZoom() + 8);
const mToPx = m => m / mpp();

/* ════════════════ MAP ════════════════ */
let map, territory = null;
let buildLayer, roadLayer, pathLayer, railLayer, crossLayer, editLayer;
let layers = {}, currentLayer = 'esri', lastMouse = null;

function initMap() {
  map = L.map('map', { zoomControl: false, attributionControl: true, worldCopyJump: true }).setView([state.view.lat, state.view.lng], state.view.zoom);
  [['pane-territory', 410], ['pane-path', 415], ['pane-lines', 420], ['pane-cross', 425], ['pane-builds', 430], ['pane-edit', 440]]
    .forEach(([n, z]) => { map.createPane(n); map.getPane(n).style.zIndex = z; });
  L.control.zoom({ position: 'topright' }).addTo(map);
  layers.esri = L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', { maxZoom: 19, attribution: 'Esri · GhostNation' });
  layers.google = L.tileLayer('https://mt{s}.google.com/vt/lyrs=s&x={x}&y={y}&z={z}', { maxZoom: 20, subdomains: ['0', '1', '2', '3'], attribution: 'Google · GhostNation' });
  layers[currentLayer].addTo(map);
  map.on('moveend', () => { const c = map.getCenter(); state.view = { lat: c.lat, lng: c.lng, zoom: map.getZoom() }; save(); });
  map.on('zoomend', () => { [roadLayer, pathLayer, railLayer].forEach(g => g && g.eachLayer(l => { if (l._mWidth != null) l.setStyle({ weight: Math.max(1, mToPx(l._mWidth)) }); })); });
  map.on('click', onMapClick);
  map.on('mousemove', e => { lastMouse = e.latlng; onMapMove(e); });
}

/* ════════════════ TOOLS ════════════════ */
let activeTool = null;
function setTool(tool) {
  if (draw.active) cancelDraw();
  if (genSel.active) endGenSelect();
  closeCtxMenu();
  deselect(); clearHover();
  activeTool = (activeTool === tool) ? null : tool;
  document.querySelectorAll('.tool[data-tool]').forEach(b => b.classList.toggle('active', b.dataset.tool === activeTool));
  const m = document.getElementById('map');
  m.classList.toggle('drawing', ['house', 'shop', 'tree'].includes(activeTool));
  m.classList.toggle('erasing', activeTool === 'erase');
  m.classList.toggle('selecting', activeTool === 'select');
  if (['borders', 'road', 'rail', 'path'].includes(activeTool)) startDraw(activeTool);
}
function setToolIdle() { activeTool = null; document.querySelectorAll('.tool[data-tool]').forEach(b => b.classList.remove('active')); document.getElementById('map').classList.remove('drawing', 'erasing', 'selecting'); }

/* ════════════════ DRAW ENGINE ════════════════ */
const draw = { active: false, mode: null, points: [], preview: null, rubber: null, handles: [] };
const LINE_STYLE = { road: '#fff', rail: '#d0d0d0', path: '#e9dec6' };
function startDraw(mode) {
  draw.active = true; draw.mode = mode; draw.points = []; draw.handles = [];
  draw.preview = (mode === 'borders')
    ? L.polygon([], { pane: 'pane-territory', color: state.color, weight: 2.5, fillColor: state.color, fillOpacity: .15, dashArray: '6 5' }).addTo(map)
    : L.polyline([], { pane: 'pane-lines', color: LINE_STYLE[mode], weight: mode === 'path' ? 3 : 4, dashArray: '6 6' }).addTo(map);
  draw.rubber = L.polyline([], { pane: 'pane-lines', color: state.color, weight: 1.6, opacity: .7, dashArray: '4 5', interactive: false }).addTo(map);
  document.getElementById('map').classList.add('drawing');
  document.getElementById('draw-bar').classList.remove('hidden');
  updateDrawHint();
}
function addVertex(latlng) {
  let snapped = false;
  if (draw.mode === 'road' || draw.mode === 'rail') { const s = snapLine(latlng); if (s) { latlng = s; snapped = true; } }
  else if (draw.mode === 'path') { const s = snapPath(latlng); if (s) { latlng = s; snapped = true; } }
  draw.points.push(latlng);
  draw.handles.push(L.marker(latlng, { pane: 'markerPane', interactive: false, keyboard: false, icon: L.divIcon({ className: '', html: `<div class="vertex-dot${snapped ? ' snapped' : ''}"></div>`, iconSize: [12, 12], iconAnchor: [6, 6] }) }).addTo(map));
  draw.preview.setLatLngs(draw.points);
  updateDrawHint();
}
function onMapMove(e) { if (draw.active && draw.points.length) draw.rubber.setLatLngs([draw.points[draw.points.length - 1], e.latlng]); }
function undoVertex() { if (!draw.points.length) return; draw.points.pop(); const h = draw.handles.pop(); if (h) map.removeLayer(h); draw.preview.setLatLngs(draw.points); if (!draw.points.length) draw.rubber.setLatLngs([]); updateDrawHint(); }
function finishDraw() {
  const min = draw.mode === 'borders' ? 3 : 2;
  if (draw.points.length < min) return;
  pushUndo();
  const pts = draw.points.map(p => [p.lat, p.lng]);
  if (draw.mode === 'borders') { state.border = pts; renderTerritory(); }
  else if (draw.mode === 'road') { state.roads.push(pts); renderRoads(); renderCrossings(); }
  else if (draw.mode === 'rail') { state.rails.push(pts); renderRails(); renderCrossings(); }
  else { state.paths.push(pts); renderPaths(); }
  save(); clearDraw(); setToolIdle(); updateStats();
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
  const hint = document.getElementById('draw-hint'), done = document.getElementById('draw-done'), n = draw.points.length;
  if (draw.mode === 'borders') { done.disabled = n < 3; hint.textContent = `Граница: ${n} ${plural(n, 'точка', 'точки', 'точек')}` + (n >= 3 ? ' · ~' + fmtArea(geodesicArea(draw.points)) : ''); }
  else { const lbl = draw.mode === 'rail' ? 'Жд' : draw.mode === 'path' ? 'Тропинка' : 'Дорога'; done.disabled = n < 2; hint.textContent = `${lbl}: ${n} ${plural(n, 'точка', 'точки', 'точек')}` + (n >= 2 ? ' · ' + fmtLen(pathLength(draw.points)) : ''); }
}

/* ════════════════ SNAP ════════════════ */
function projSeg(p, a, b) { const dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy; if (l2 === 0) return a; let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2; t = Math.max(0, Math.min(1, t)); return L.point(a.x + t * dx, a.y + t * dy); }
function snapLine(latlng) {            // snap to roads + rails (exact)
  const p = map.latLngToLayerPoint(latlng); let best = null, bestD = SNAP_PX;
  for (const line of state.roads.concat(state.rails)) for (let i = 0; i < line.length; i++) {
    const v = map.latLngToLayerPoint(L.latLng(line[i][0], line[i][1]));
    if (p.distanceTo(v) < bestD) { bestD = p.distanceTo(v); best = L.latLng(line[i][0], line[i][1]); }
    if (i > 0) { const a = map.latLngToLayerPoint(L.latLng(line[i - 1][0], line[i - 1][1])); const pr = projSeg(p, a, v); if (p.distanceTo(pr) < bestD) { bestD = p.distanceTo(pr); best = map.layerPointToLatLng(pr); } }
  }
  return best;
}
function snapPath(latlng) {             // paths: exact; roads: offset to side (тротуар)
  const p = map.latLngToLayerPoint(latlng); let best = null, bestD = SNAP_PX;
  for (const line of state.paths) for (let i = 0; i < line.length; i++) {
    const v = map.latLngToLayerPoint(L.latLng(line[i][0], line[i][1]));
    if (p.distanceTo(v) < bestD) { bestD = p.distanceTo(v); best = L.latLng(line[i][0], line[i][1]); }
    if (i > 0) { const a = map.latLngToLayerPoint(L.latLng(line[i - 1][0], line[i - 1][1])); const pr = projSeg(p, a, v); if (p.distanceTo(pr) < bestD) { bestD = p.distanceTo(pr); best = map.layerPointToLatLng(pr); } }
  }
  const sideOff = mToPx(SIDEWALK_OFF);
  for (const line of state.roads) for (let i = 1; i < line.length; i++) {
    const a = map.latLngToLayerPoint(L.latLng(line[i - 1][0], line[i - 1][1])), b = map.latLngToLayerPoint(L.latLng(line[i][0], line[i][1]));
    const pr = projSeg(p, a, b);
    if (p.distanceTo(pr) > SNAP_PX + sideOff) continue;
    let nx = -(b.y - a.y), ny = (b.x - a.x); const nl = Math.hypot(nx, ny) || 1; nx /= nl; ny /= nl;
    if ((p.x - pr.x) * nx + (p.y - pr.y) * ny < 0) { nx = -nx; ny = -ny; }
    const op = L.point(pr.x + nx * sideOff, pr.y + ny * sideOff);
    if (p.distanceTo(op) < bestD) { bestD = p.distanceTo(op); best = map.layerPointToLatLng(op); }
  }
  return best;
}
function nearestRoad(lat, lng) {        // globally nearest road point + bearing (no threshold)
  const p = map.latLngToLayerPoint(L.latLng(lat, lng)); let best = null, bestD = Infinity;
  for (const road of state.roads) for (let i = 1; i < road.length; i++) {
    const a = map.latLngToLayerPoint(L.latLng(road[i - 1][0], road[i - 1][1])), b = map.latLngToLayerPoint(L.latLng(road[i][0], road[i][1]));
    const pr = projSeg(p, a, b), d = p.distanceTo(pr);
    if (d < bestD) { bestD = d; const ll = map.layerPointToLatLng(pr); const E = (road[i][1] - road[i - 1][1]) * mPerDegLng(lat), N = (road[i][0] - road[i - 1][0]) * MPD_LAT; best = { bearing: Math.atan2(N, E) * 180 / Math.PI, lat: ll.lat, lng: ll.lng }; }
  }
  return best;
}
function setDoorToward(b, rlat, rlng) {  // entrance side facing a given road point
  const E = (rlng - b.lng) * mPerDegLng(b.lat), N = (rlat - b.lat) * MPD_LAT, a = (b.rot || 0) * Math.PI / 180;
  b.door = (-E * Math.sin(a) + N * Math.cos(a)) >= 0 ? 2 : 0;
}
function alignToRoad(b) {                // rotate along nearest road, entrance facing it
  const info = nearestRoad(b.lat, b.lng);
  if (!info) { b.rot = Math.round(rand(0, 360)); b.door = randInt(4); return; }
  b.rot = Math.round(info.bearing); setDoorToward(b, info.lat, info.lng);
}

/* ════════════════ MAP CLICK / PLACE ════════════════ */
function onMapClick(e) {
  closeCtxMenu();
  if (genSel.active) return;
  if (draw.active) { addVertex(e.latlng); return; }
  if (activeTool === 'select') { deselect(); return; }
  if (['house', 'shop', 'tree'].includes(activeTool)) placeBuilding(activeTool, e.latlng);
}
function bRadius(b) { return b.type === 'tree' ? clampR(b.r ?? DEF.tree.r) : Math.hypot(clampWH(b.w ?? DEF[b.type].w) / 2, clampWH(b.h ?? DEF[b.type].h) / 2); }
function distMeters(la1, ln1, la2, ln2) { const E = (ln2 - ln1) * mPerDegLng(la1), N = (la2 - la1) * MPD_LAT; return Math.hypot(E, N); }
function overlapsAt(lat, lng, radius, exclude) { for (const o of state.buildings) { if (o === exclude) continue; if (distMeters(lat, lng, o.lat, o.lng) < radius + bRadius(o)) return true; } return false; }
function insideBuilding(lat, lng) { for (const o of state.buildings) if (distMeters(lat, lng, o.lat, o.lng) < bRadius(o) + 1) return true; return false; }
function freeSpot(lat, lng, radius) {
  for (let ring = 1; ring <= 9; ring++) { const dist = ring * (radius * 2 + 3); for (let k = 0; k < 8; k++) { const ang = k / 8 * 2 * Math.PI, ll = offset(lat, lng, Math.cos(ang) * dist, Math.sin(ang) * dist); if (!overlapsAt(ll[0], ll[1], radius)) return { lat: ll[0], lng: ll[1] }; } }
  return { lat, lng };
}
function pointSegDistM(plat, plng, a, b) {     // metres from point to road segment
  const mlng = mPerDegLng(a[0]), bx = (b[1] - a[1]) * mlng, by = (b[0] - a[0]) * MPD_LAT;
  const px = (plng - a[1]) * mlng, py = (plat - a[0]) * MPD_LAT, l2 = bx * bx + by * by;
  let t = l2 ? (px * bx + py * by) / l2 : 0; t = Math.max(0, Math.min(1, t));
  return Math.hypot(px - t * bx, py - t * by);
}
function buildingHitsRoad(b) {                  // any corner / porch within road half-width of any road
  const pts = [[b.lat, b.lng], ...rectCorners(b)]; const dr = doorRect(b); pts.push(dr[2], dr[3]);
  for (const road of state.roads) for (let i = 1; i < road.length; i++)
    for (const p of pts) if (pointSegDistM(p[0], p[1], road[i - 1], road[i]) < LINE_M.road / 2 + 0.3) return true;
  return false;
}
function placeBuilding(type, latlng) {
  pushUndo();
  const b = { type, lat: latlng.lat, lng: latlng.lng };
  if (type === 'tree') {
    b.r = DEF.tree.r;
    if (overlapsAt(b.lat, b.lng, b.r, b)) { const f = freeSpot(b.lat, b.lng, b.r); b.lat = f.lat; b.lng = f.lng; }
  } else {
    if (insideBuilding(b.lat, b.lng)) { const f = freeSpot(b.lat, b.lng, 8); b.lat = f.lat; b.lng = f.lng; }
    alignToRoad(b);
    let maxS = 30;                                  // random size, shrink on touch, relocate if stuck
    for (let t = 0; t < 12; t++) {
      b.w = Math.round(rand(8, maxS)); b.h = Math.round(rand(8, maxS));
      if (!overlapsAt(b.lat, b.lng, bRadius(b), b)) break;
      if (maxS > 8) maxS = Math.max(8, maxS * 0.8);
      else { const f = freeSpot(b.lat, b.lng, bRadius(b)); b.lat = f.lat; b.lng = f.lng; alignToRoad(b); }
    }
  }
  state.buildings.push(b); save(); renderBuildings(); updateStats();
  return b;
}

/* ════════════════ SETTLE (buildings drift toward road) ════════════════ */
function settleToRoad(b) {
  if (b.type === 'tree') return false;
  const info = nearestRoad(b.lat, b.lng); if (!info) return false;
  const E = (info.lng - b.lng) * mPerDegLng(b.lat), N = (info.lat - b.lat) * MPD_LAT, dist = Math.hypot(E, N);
  const want = LINE_M.road / 2 + clampWH(b.h) / 2 + PORCH_DEPTH + BUILD_GAP;
  if (dist <= want + 0.3) return false;
  const step = Math.min(dist - want, 12), f = step / dist;
  const nlat = b.lat + N * f / MPD_LAT, nlng = b.lng + E * f / mPerDegLng(b.lat);
  if (overlapsAt(nlat, nlng, bRadius(b), b) || buildingHitsRoad({ ...b, lat: nlat, lng: nlng })) return false;
  b.lat = nlat; b.lng = nlng; alignToRoad(b); return true;
}
function settlePass(times) { let moved = true, it = 0; while (moved && it++ < (times || 20)) { moved = false; for (const b of state.buildings) if (settleToRoad(b)) moved = true; } }
function settleAll() { pushUndo(); settlePass(25); save(); renderBuildings(); renderPaths(); updateStats(); flash('Здания подтянуты к дороге'); }

/* ════════════════ AUTO-GENERATION ALONG A ROAD ════════════════ */
function addWalkway(b) {                 // дорожка от крыльца к тротуару дороги
  const dr = doorRect(b), ent = [(dr[2][0] + dr[3][0]) / 2, (dr[2][1] + dr[3][1]) / 2];
  const info = nearestRoad(b.lat, b.lng); if (!info) return;
  const a = info.bearing * Math.PI / 180; let pE = -Math.sin(a), pN = Math.cos(a);
  const tE = (b.lng - info.lng) * mPerDegLng(b.lat), tN = (b.lat - info.lat) * MPD_LAT;
  if (pE * tE + pN * tN < 0) { pE = -pE; pN = -pN; }
  state.paths.push([ent, offset(info.lat, info.lng, pE * SIDEWALK_OFF, pN * SIDEWALK_OFF)]);
}
function runGeneration(pairs) {
  pushUndo();
  const stepM = 20, rowGap = 8;
  let shops = 0; const made = [];
  pairs.forEach(([road, si]) => {
    const a = road[si], b = road[si + 1], lat = a[0];
    const E = (b[1] - a[1]) * mPerDegLng(lat), N = (b[0] - a[0]) * MPD_LAT, len = Math.hypot(E, N);
    if (len < 8) return;
    const ux = E / len, uy = N / len, px = -uy, py = ux, bearing = Math.round(Math.atan2(N, E) * 180 / Math.PI);
    for (let d = stepM / 2; d < len - 2; d += stepM) {
      const cy = a[0] + uy * d / MPD_LAT, cx = a[1] + ux * d / mPerDegLng(lat);
      for (const side of [1, -1]) {                                   // обе стороны
        const rows = 1 + (Math.random() < 0.5 ? 1 : 0) + (Math.random() < 0.18 ? 1 : 0);
        let edge = LINE_M.road / 2 + PORCH_DEPTH + BUILD_GAP;          // ближняя грань первого ряда
        for (let row = 0; row < rows; row++) {
          const w = Math.round(rand(9, 18)), h = Math.round(rand(9, 16)), c = edge + h / 2;
          const isShop = Math.random() < 0.13 / (1 + shops * 1.3);     // шанс падает с числом магазинов
          const nb = { type: isShop ? 'shop' : 'house', lat: cy + py * c * side / MPD_LAT, lng: cx + px * c * side / mPerDegLng(cy), w, h, rot: bearing };
          setDoorToward(nb, cy, cx);
          if (!overlapsAt(nb.lat, nb.lng, bRadius(nb)) && !buildingHitsRoad(nb)) {
            state.buildings.push(nb); made.push(nb); if (isShop) shops++;
            if (row === 0) addWalkway(nb);
          }
          edge = c + h / 2 + rowGap;                                    // следующий ряд дальше
        }
      }
    }
  });
  if (shops === 0) { const hs = made.filter(b => b.type === 'house'); if (hs.length) hs[randInt(hs.length)].type = 'shop'; }  // минимум 1 магазин
  save(); renderBuildings(); renderPaths(); updateStats(); flash(`Застройка: +${made.length}`);
}

/* ════════════════ ROAD CONTEXT MENU + SEGMENT SELECTION ════════════════ */
let genSel = { active: false, segs: null, layer: null };
function closeCtxMenu() { const m = document.getElementById('ctx-menu'); if (m) m.classList.add('hidden'); }
function openRoadMenu(e, road) {
  closeCtxMenu();
  const m = document.getElementById('ctx-menu'); m.innerHTML = '';
  [['Авто-застройка вдоль дороги', () => { closeCtxMenu(); startGenSelect(road); }],
   ['Подтянуть здания к дороге', () => { closeCtxMenu(); settleAll(); }]]
    .forEach(([label, fn]) => { const btn = document.createElement('button'); btn.className = 'ctx-item'; btn.textContent = label; btn.onclick = fn; m.appendChild(btn); });
  const o = e.originalEvent;
  m.classList.remove('hidden');
  m.style.left = Math.min(window.innerWidth - m.offsetWidth - 8, o.clientX) + 'px';
  m.style.top = Math.min(window.innerHeight - m.offsetHeight - 8, o.clientY) + 'px';
}
function startGenSelect(road) {
  genSel.active = true; genSel.segs = new Set();
  const ri = state.roads.indexOf(road);
  for (let si = 0; si < road.length - 1; si++) genSel.segs.add(ri + ':' + si);   // по умолчанию — кликнутая дорога
  genSel.layer = L.layerGroup().addTo(map);
  drawGenSegs();
  document.getElementById('gen-bar').classList.remove('hidden');
  document.getElementById('map').classList.add('selecting');
}
function drawGenSegs() {                          // кликабельны сегменты ВСЕХ дорог
  genSel.layer.clearLayers();
  state.roads.forEach((road, ri) => {
    for (let si = 0; si < road.length - 1; si++) {
      const key = ri + ':' + si, sel = genSel.segs.has(key);
      const ln = L.polyline([road[si], road[si + 1]], { pane: 'pane-edit', color: sel ? '#D97757' : '#9aa0a6', weight: 9, opacity: sel ? .85 : .4 }).addTo(genSel.layer);
      ln.on('click', ev => { L.DomEvent.stop(ev); genSel.segs.has(key) ? genSel.segs.delete(key) : genSel.segs.add(key); drawGenSegs(); });
    }
  });
}
function endGenSelect() { genSel.active = false; if (genSel.layer) { map.removeLayer(genSel.layer); genSel.layer = null; } genSel.segs = null; document.getElementById('gen-bar').classList.add('hidden'); document.getElementById('map').classList.remove('selecting'); }
function confirmGen() {
  const pairs = (genSel.segs ? [...genSel.segs] : []).map(k => { const [ri, si] = k.split(':').map(Number); return [state.roads[ri], si]; }).filter(p => p[0]);
  endGenSelect();
  if (pairs.length) runGeneration(pairs);
}

/* ════════════════ BUILDING GEOMETRY ════════════════ */
function rectCorners(b) {
  const w = clampWH(b.w ?? DEF[b.type].w), h = clampWH(b.h ?? DEF[b.type].h), a = (b.rot || 0) * Math.PI / 180, ca = Math.cos(a), sa = Math.sin(a);
  return [[-w / 2, -h / 2], [w / 2, -h / 2], [w / 2, h / 2], [-w / 2, h / 2]].map(([dx, dy]) => offset(b.lat, b.lng, dx * ca - dy * sa, dx * sa + dy * ca));
}
function ridgeEnds(b) {
  const w = clampWH(b.w ?? DEF[b.type].w), a = (b.rot || 0) * Math.PI / 180, ca = Math.cos(a), sa = Math.sin(a);
  return [offset(b.lat, b.lng, -w / 2 * ca, -w / 2 * sa), offset(b.lat, b.lng, w / 2 * ca, w / 2 * sa)];
}
function doorRect(b) {                  // крыльцо на стороне входа
  const w = clampWH(b.w ?? DEF[b.type].w), h = clampWH(b.h ?? DEF[b.type].h), a = (b.rot || 0) * Math.PI / 180, ca = Math.cos(a), sa = Math.sin(a);
  const d = (b.door || 0) % 4, pd = PORCH_DEPTH, pw = Math.max(2, Math.min(w, h) * 0.4);
  let mid, out, tan;
  if (d === 0) { mid = [0, -h / 2]; out = [0, -1]; tan = [1, 0]; }
  else if (d === 1) { mid = [w / 2, 0]; out = [1, 0]; tan = [0, 1]; }
  else if (d === 2) { mid = [0, h / 2]; out = [0, 1]; tan = [1, 0]; }
  else { mid = [-w / 2, 0]; out = [-1, 0]; tan = [0, 1]; }
  const hw = pw / 2;
  return [
    [mid[0] + tan[0] * hw, mid[1] + tan[1] * hw],
    [mid[0] - tan[0] * hw, mid[1] - tan[1] * hw],
    [mid[0] - tan[0] * hw + out[0] * pd, mid[1] - tan[1] * hw + out[1] * pd],
    [mid[0] + tan[0] * hw + out[0] * pd, mid[1] + tan[1] * hw + out[1] * pd],
  ].map(([dx, dy]) => offset(b.lat, b.lng, dx * ca - dy * sa, dx * sa + dy * ca));
}

/* ════════════════ RENDER: TERRITORY / BUILDINGS ════════════════ */
function renderTerritory() {
  if (territory) { map.removeLayer(territory); territory = null; }
  if (!state.border) return;
  territory = L.polygon(state.border, { pane: 'pane-territory', color: state.color, weight: 2.5, opacity: .95, fillColor: state.color, fillOpacity: .18 }).addTo(map);
  territory.on('click', e => { if (activeTool !== 'erase') return; L.DomEvent.stop(e); pushUndo(); state.border = null; save(); renderTerritory(); updateStats(); });
}

const blMap = new Map();
function insetRect(b, s) {
  const w = clampWH(b.w ?? DEF[b.type].w) * s, h = clampWH(b.h ?? DEF[b.type].h) * s, a = (b.rot || 0) * Math.PI / 180, ca = Math.cos(a), sa = Math.sin(a);
  return [[-w / 2, -h / 2], [w / 2, -h / 2], [w / 2, h / 2], [-w / 2, h / 2]].map(([dx, dy]) => offset(b.lat, b.lng, dx * ca - dy * sa, dx * sa + dy * ca));
}
function roofFacets(b) {                 // hip roof: 2 slopes + 2 hip ends + ridge
  const w = clampWH(b.w ?? DEF[b.type].w), h = clampWH(b.h ?? DEF[b.type].h), a = (b.rot || 0) * Math.PI / 180, ca = Math.cos(a), sa = Math.sin(a);
  const P = (dx, dy) => offset(b.lat, b.lng, dx * ca - dy * sa, dx * sa + dy * ca);
  const c0 = [-w / 2, -h / 2], c1 = [w / 2, -h / 2], c2 = [w / 2, h / 2], c3 = [-w / 2, h / 2];
  let R1, R2, s1, s2, t1, t2;
  if (w >= h) { const e = Math.max(0, w / 2 - h / 2); R1 = [-e, 0]; R2 = [e, 0]; s1 = [c0, c1, R2, R1]; s2 = [c3, c2, R2, R1]; t1 = [c0, R1, c3]; t2 = [c1, R2, c2]; }
  else { const e = Math.max(0, h / 2 - w / 2); R1 = [0, -e]; R2 = [0, e]; s1 = [c0, c3, R2, R1]; s2 = [c1, c2, R2, R1]; t1 = [c0, R1, c1]; t2 = [c3, R2, c2]; }
  return { slope1: s1.map(p => P(...p)), slope2: s2.map(p => P(...p)), hip1: t1.map(p => P(...p)), hip2: t2.map(p => P(...p)), ridge: [P(...R1), P(...R2)] };
}
function drawHouse(b) {
  const corners = rectCorners(b), out = [];
  if (b.type === 'shop') {
    out.push(L.polygon(corners, { pane: 'pane-builds', color: '#ffffff', weight: 4, fillColor: ROOF.shop.fill, fillOpacity: .95 }).addTo(buildLayer));   // parapet
    out.push(L.polygon(insetRect(b, 0.66), { pane: 'pane-builds', color: '#173b6b', weight: 1, fillColor: '#2f6fc4', fillOpacity: .97 }).addTo(buildLayer)); // roof field
    out.push(L.polygon(insetRect(b, 0.30), { pane: 'pane-builds', color: '#0e294e', weight: 1, fillColor: '#1d4f93', fillOpacity: .97 }).addTo(buildLayer)); // rooftop unit
  } else {
    const f = roofFacets(b);
    out.push(L.polygon(f.slope1, { pane: 'pane-builds', color: ROOF.house.edge, weight: 1, fillColor: '#44c65a', fillOpacity: .97 }).addTo(buildLayer));
    out.push(L.polygon(f.slope2, { pane: 'pane-builds', color: ROOF.house.edge, weight: 1, fillColor: '#2f9d43', fillOpacity: .97 }).addTo(buildLayer));
    out.push(L.polygon(f.hip1, { pane: 'pane-builds', color: ROOF.house.edge, weight: 1, fillColor: '#23823a', fillOpacity: .97 }).addTo(buildLayer));
    out.push(L.polygon(f.hip2, { pane: 'pane-builds', color: ROOF.house.edge, weight: 1, fillColor: '#23823a', fillOpacity: .97 }).addTo(buildLayer));
    out.push(L.polyline(f.ridge, { pane: 'pane-builds', color: '#eafff0', weight: 1.8, opacity: .95 }).addTo(buildLayer));
  }
  out.push(L.polygon(doorRect(b), { pane: 'pane-builds', color: '#7a4a12', weight: 1, fillColor: PORCH, fillOpacity: .95 }).addTo(buildLayer));
  out.forEach(l => { l.on('click', e => onBuildClick(b, e)); l.on('mouseover', () => hoverBuilding(b)); l.on('mouseout', clearHover); });
  return out;
}
function drawTree(b) {
  const c = L.circle([b.lat, b.lng], { pane: 'pane-builds', radius: clampR(b.r ?? DEF.tree.r), color: '#16551f', weight: 1, fillColor: '#2f9a44', fillOpacity: .9 }).addTo(buildLayer);
  c.on('click', e => onBuildClick(b, e)); c.on('mouseover', () => hoverBuilding(b)); c.on('mouseout', clearHover);
  return [c];
}
function renderBuildings() { buildLayer.clearLayers(); blMap.clear(); state.buildings.forEach(b => blMap.set(b, b.type === 'tree' ? drawTree(b) : drawHouse(b))); }
function updateBuildingGeom(b) { const old = blMap.get(b); if (old) old.forEach(l => buildLayer.removeLayer(l)); blMap.set(b, b.type === 'tree' ? drawTree(b) : drawHouse(b)); }
function onBuildClick(b, e) { if (activeTool === 'erase') { L.DomEvent.stop(e); removeBuilding(b); } else if (activeTool === 'select') { L.DomEvent.stop(e); selectBuilding(b); } }
function removeBuilding(b) { pushUndo(); if (selected === b) deselect(); clearHover(); state.buildings = state.buildings.filter(x => x !== b); save(); renderBuildings(); updateStats(); }

/* ════════════════ HOVER HIGHLIGHT ════════════════ */
let hoverHL = null;
function clearHover() { if (hoverHL) { map.removeLayer(hoverHL); hoverHL = null; } }
function hoverBuilding(b) {
  if (selected === b) return;
  const danger = activeTool === 'erase';
  clearHover();
  const o = { pane: 'pane-edit', interactive: false, color: danger ? '#E0245E' : '#fff', weight: 2.5, fill: false };
  hoverHL = b.type === 'tree' ? L.circle([b.lat, b.lng], { ...o, radius: clampR(b.r) }) : L.polygon(rectCorners(b), { ...o, dashArray: danger ? null : '4 3' });
  hoverHL.addTo(map);
}
function hoverSeg(latlng, line) {
  const seg = nearestSeg(latlng, line); if (!seg) return;
  clearHover();
  hoverHL = L.polyline(seg, { pane: 'pane-edit', interactive: false, color: activeTool === 'erase' ? '#E0245E' : '#fff', weight: 7, opacity: .65, lineCap: 'round' }).addTo(map);
}
function nearestSegIdx(latlng, line) {
  const p = map.latLngToLayerPoint(latlng); let idx = 0, bestD = Infinity;
  for (let i = 1; i < line.length; i++) {
    const a = map.latLngToLayerPoint(L.latLng(line[i - 1][0], line[i - 1][1])), b = map.latLngToLayerPoint(L.latLng(line[i][0], line[i][1]));
    const d = p.distanceTo(projSeg(p, a, b)); if (d < bestD) { bestD = d; idx = i - 1; }
  }
  return idx;
}
function nearestSeg(latlng, line) { if (line.length < 2) return null; const i = nearestSegIdx(latlng, line); return [line[i], line[i + 1]]; }

/* ════════════════ RENDER: ROADS / PATHS / RAILS / CROSS ════════════════ */
function roadPx() { return Math.max(2.5, mToPx(LINE_M.road)); }
function railPx() { return Math.max(2.5, mToPx(LINE_M.rail)); }
function pathPx() { return Math.max(1.5, mToPx(LINE_M.path)); }
const tagW = (layer, m) => { layer._mWidth = m; return layer; };   // mark metre-width for zoom rescale

function lineHandlers(layer, key, line) {
  layer.on('click', e => { if (activeTool !== 'erase') return; L.DomEvent.stop(e); eraseSegment(key, line, e.latlng); });
  layer.on('mousemove', e => hoverSeg(e.latlng, line));
  layer.on('mouseout', clearHover);
}
function renderRoads() {
  roadLayer.clearLayers(); const w = roadPx();
  const sw = Math.max(2, mToPx(LINE_M.path + 0.6));
  state.roads.forEach(r => {
    [SIDEWALK_OFF, -SIDEWALK_OFF].forEach(o => tagW(L.polyline(offsetLine(r, o), { pane: 'pane-path', color: '#b7b9bc', weight: sw, opacity: .92, interactive: false, lineCap: 'round' }).addTo(roadLayer), LINE_M.path + 0.6));   // тротуары вдоль дороги
    const asphalt = tagW(L.polyline(r, { pane: 'pane-lines', color: '#3b3f45', weight: w, opacity: .97, lineCap: 'round', lineJoin: 'round' }).addTo(roadLayer), LINE_M.road);
    tagW(L.polyline(r, { pane: 'pane-lines', color: '#f2c200', weight: Math.max(1, w * 0.11), opacity: .9, dashArray: `${Math.max(4, w * 0.8)} ${Math.max(6, w * 1.3)}`, interactive: false }).addTo(roadLayer), LINE_M.road * 0.11);
    asphalt.on('click', e => {
      if (activeTool === 'erase') { L.DomEvent.stop(e); eraseSegment('roads', r, e.latlng); }
      else if (!activeTool && !draw.active && !genSel.active) { L.DomEvent.stop(e); openRoadMenu(e, r); }
    });
    asphalt.on('mousemove', e => { if (activeTool === 'erase') hoverSeg(e.latlng, r); });
    asphalt.on('mouseout', clearHover);
  });
}
function renderPaths() {
  pathLayer.clearLayers(); const w = Math.max(2, pathPx());
  state.paths.forEach(pp => {
    const ln = tagW(L.polyline(pp, { pane: 'pane-path', color: '#b7b9bc', weight: w, opacity: .96, lineCap: 'round', lineJoin: 'round' }).addTo(pathLayer), LINE_M.path);
    lineHandlers(ln, 'paths', pp);
  });
}
function offsetLine(latlngs, metres) {     // geographic perpendicular offset (zoom-independent)
  const segNormal = (a, b) => { const dE = (b[1] - a[1]) * mPerDegLng(a[0]), dN = (b[0] - a[0]) * MPD_LAT, l = Math.hypot(dE, dN) || 1; return [-dN / l, dE / l]; };
  return latlngs.map((p, i) => {
    let nx = 0, ny = 0;
    if (i > 0) { const n = segNormal(latlngs[i - 1], p); nx += n[0]; ny += n[1]; }
    if (i < latlngs.length - 1) { const n = segNormal(p, latlngs[i + 1]); nx += n[0]; ny += n[1]; }
    const nl = Math.hypot(nx, ny) || 1;
    return offset(p[0], p[1], nx / nl * metres, ny / nl * metres);
  });
}
function railTies(latlngs, halfM, spacingM) {
  const out = [];
  for (let i = 1; i < latlngs.length; i++) {
    const a = latlngs[i - 1], b = latlngs[i], lat = a[0], E = (b[1] - a[1]) * mPerDegLng(lat), N = (b[0] - a[0]) * MPD_LAT, len = Math.hypot(E, N);
    if (len < 0.5) continue;
    const ux = E / len, uy = N / len, px = -uy, py = ux;
    for (let d = spacingM / 2; d < len; d += spacingM) { const cy = a[0] + uy * d / MPD_LAT, cx = a[1] + ux * d / mPerDegLng(lat); out.push([offset(cy, cx, px * halfM, py * halfM), offset(cy, cx, -px * halfM, -py * halfM)]); }
  }
  return out;
}
function renderRails() {
  railLayer.clearLayers(); const w = railPx(), tieW = Math.max(2, w * 0.2), railW = Math.max(1, w * 0.12), halfBed = LINE_M.rail * 0.5, gauge = LINE_M.rail * 0.34;
  state.rails.forEach(r => {
    const bed = tagW(L.polyline(r, { pane: 'pane-lines', color: '#5b4f43', weight: w, opacity: .95, lineCap: 'round', lineJoin: 'round' }).addTo(railLayer), LINE_M.rail);
    railTies(r, halfBed, 6).forEach(seg => tagW(L.polyline(seg, { pane: 'pane-lines', color: '#d8d2c6', weight: tieW, opacity: .9, interactive: false }).addTo(railLayer), LINE_M.rail * 0.2));
    [gauge, -gauge].forEach(g => tagW(L.polyline(offsetLine(r, g), { pane: 'pane-lines', color: '#20242a', weight: railW, opacity: .95, interactive: false }).addTo(railLayer), LINE_M.rail * 0.12));
    bed.on('click', e => { if (activeTool !== 'erase') return; L.DomEvent.stop(e); eraseSegment('rails', r, e.latlng); });
    bed.on('mousemove', e => hoverSeg(e.latlng, r)); bed.on('mouseout', clearHover);
  });
}
function eraseSegment(key, line, latlng) {
  pushUndo();
  const arr = state[key], pos = arr.indexOf(line); if (pos < 0) return;
  const i = nearestSegIdx(latlng, line), before = line.slice(0, i + 1), after = line.slice(i + 1), repl = [];
  if (before.length >= 2) repl.push(before); if (after.length >= 2) repl.push(after);
  arr.splice(pos, 1, ...repl);
  clearHover(); save();
  ({ roads: renderRoads, paths: renderPaths, rails: renderRails }[key])();
  renderCrossings(); updateStats();
}
function segInter(p1, p2, p3, p4) {
  const x1 = p1[1], y1 = p1[0], x2 = p2[1], y2 = p2[0], x3 = p3[1], y3 = p3[0], x4 = p4[1], y4 = p4[0];
  const d = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4); if (Math.abs(d) < 1e-14) return null;
  const t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / d, u = ((x1 - x3) * (y1 - y2) - (y1 - y3) * (x1 - x2)) / d;
  if (t < 0 || t > 1 || u < 0 || u > 1) return null;
  return [y1 + t * (y2 - y1), x1 + t * (x2 - x1)];
}
function renderCrossings() {
  crossLayer.clearLayers();
  for (const road of state.roads) for (let i = 1; i < road.length; i++)
    for (const rail of state.rails) for (let j = 1; j < rail.length; j++) {
      const X = segInter(road[i - 1], road[i], rail[j - 1], rail[j]); if (X) drawCrossing(X, road[i - 1], road[i]);
    }
}
function drawCrossing(X, ra, rb) {
  const lat = X[0], E = (rb[1] - ra[1]) * mPerDegLng(lat), N = (rb[0] - ra[0]) * MPD_LAT, ang = Math.atan2(N, E), ca = Math.cos(ang), sa = Math.sin(ang);
  const along = Math.max(LINE_M.rail, LINE_M.road) * 1.5 / 2, across = LINE_M.road * 1.1 / 2;
  const at = (dl, dw) => offset(X[0], X[1], dl * ca - dw * sa, dl * sa + dw * ca);
  L.polygon([at(along, across), at(along, -across), at(-along, -across), at(-along, across)], { pane: 'pane-cross', color: '#fff', weight: 1.5, fillColor: '#33373d', fillOpacity: .97 }).addTo(crossLayer);
  for (const f of [-0.5, 0.5]) L.polyline([at(f * along, across), at(f * along, -across)], { pane: 'pane-cross', color: '#f2c200', weight: 2, opacity: .95, interactive: false }).addTo(crossLayer);
}

function renderAll() { renderTerritory(); renderRoads(); renderPaths(); renderRails(); renderCrossings(); renderBuildings(); updateStats(); document.getElementById('state-name').value = state.name; paintFlag(); updateUndoBtn(); }

/* ════════════════ EDITOR ════════════════ */
let selected = null, eh = {};
function selectBuilding(b, switchTool) {
  if (switchTool) { activeTool = 'select'; document.querySelectorAll('.tool[data-tool]').forEach(x => x.classList.toggle('active', x.dataset.tool === 'select')); document.getElementById('map').classList.add('selecting'); document.getElementById('map').classList.remove('drawing'); }
  selected = b; clearHover();
  if (b.type === 'tree') b.r = clampR(b.r ?? DEF.tree.r);
  else { b.w = clampWH(b.w ?? DEF[b.type].w); b.h = clampWH(b.h ?? DEF[b.type].h); b.rot = b.rot || 0; if (b.door == null) b.door = 0; }
  renderEdit(); document.getElementById('edit').classList.remove('hidden'); updateEditMeta();
}
function deselect() { selected = null; if (editLayer) editLayer.clearLayers(); eh = {}; const p = document.getElementById('edit'); if (p) p.classList.add('hidden'); }
function rotHandlePos(b) { const a = (b.rot || 0) * Math.PI / 180, d = clampWH(b.h) / 2 + 9; return offset(b.lat, b.lng, -d * Math.sin(a), d * Math.cos(a)); }
function sizeHandlePos(b) { const a = (b.rot || 0) * Math.PI / 180, ca = Math.cos(a), sa = Math.sin(a), dx = clampWH(b.w) / 2, dy = clampWH(b.h) / 2; return offset(b.lat, b.lng, dx * ca - dy * sa, dx * sa + dy * ca); }
function treeEdgePos(b) { return offset(b.lat, b.lng, clampR(b.r), 0); }
function handleMarker(cls, pos) { const m = L.marker(pos, { pane: 'markerPane', draggable: true, icon: L.divIcon({ className: '', html: `<div class="edit-handle ${cls}"></div>`, iconSize: [16, 16], iconAnchor: [8, 8] }) }).addTo(editLayer); m.on('dragstart', () => pushUndo()); return m; }
function renderEdit() {
  editLayer.clearLayers(); eh = {}; const b = selected; if (!b) return;
  const tree = b.type === 'tree';
  eh.highlight = L.polygon(tree ? [] : rectCorners(b), { pane: 'pane-edit', color: '#D97757', weight: 2, dashArray: '5 4', fill: false, interactive: false }).addTo(editLayer);
  eh.move = handleMarker('h-move', [b.lat, b.lng]);
  eh.move.on('drag', e => { b.lat = e.latlng.lat; b.lng = e.latlng.lng; updateBuildingGeom(b); posHandles('move'); updateEditMeta(); });
  eh.move.on('dragend', save);
  if (tree) {
    eh.size = handleMarker('h-size', treeEdgePos(b));
    eh.size.on('drag', e => { b.r = clampR(distM(b, e.latlng)); updateBuildingGeom(b); posHandles('size'); updateEditMeta(); }); eh.size.on('dragend', save);
  } else {
    eh.rot = handleMarker('h-rot', rotHandlePos(b));
    eh.rot.on('drag', e => { b.rot = bearing(b, e.latlng); updateBuildingGeom(b); posHandles('rot'); updateEditMeta(); }); eh.rot.on('dragend', save);
    eh.size = handleMarker('h-size', sizeHandlePos(b));
    eh.size.on('drag', e => { applyResize(b, e.latlng); updateBuildingGeom(b); posHandles('size'); updateEditMeta(); }); eh.size.on('dragend', save);
  }
}
function posHandles(except) {
  const b = selected; if (!b) return;
  if (b.type !== 'tree') eh.highlight.setLatLngs(rectCorners(b));
  if (except !== 'move' && eh.move) eh.move.setLatLng([b.lat, b.lng]);
  if (b.type === 'tree') { if (except !== 'size') eh.size.setLatLng(treeEdgePos(b)); }
  else { if (except !== 'rot' && eh.rot) eh.rot.setLatLng(rotHandlePos(b)); if (except !== 'size' && eh.size) eh.size.setLatLng(sizeHandlePos(b)); }
}
function distM(b, ll) { const E = (ll.lng - b.lng) * mPerDegLng(b.lat), N = (ll.lat - b.lat) * MPD_LAT; return Math.hypot(E, N); }
function bearing(b, ll) { const E = (ll.lng - b.lng) * mPerDegLng(b.lat), N = (ll.lat - b.lat) * MPD_LAT; return Math.atan2(-E, N) * 180 / Math.PI; }
function applyResize(b, ll) { const E = (ll.lng - b.lng) * mPerDegLng(b.lat), N = (ll.lat - b.lat) * MPD_LAT, a = (b.rot || 0) * Math.PI / 180, ca = Math.cos(a), sa = Math.sin(a); b.w = clampWH(Math.abs(E * ca + N * sa) * 2); b.h = clampWH(Math.abs(-E * sa + N * ca) * 2); }
function updateEditMeta() {
  const b = selected; if (!b) return;
  document.getElementById('edit-title').textContent = b.type === 'house' ? 'Жилой дом' : b.type === 'shop' ? 'Магазин' : 'Дерево';
  document.getElementById('edit-meta').textContent = b.type === 'tree' ? `R ${clampR(b.r).toFixed(1)} м` : `${Math.round(clampWH(b.w))}×${Math.round(clampWH(b.h))} м · ${Math.round(((b.rot || 0) % 360 + 360) % 360)}°`;
}

/* ════════════════ COPY / PASTE ════════════════ */
let clipboard = null;
function copySel() { if (selected) { clipboard = JSON.parse(JSON.stringify(selected)); flash('Скопировано'); } }
function paste() {
  if (!clipboard) return;
  pushUndo();
  const b = JSON.parse(JSON.stringify(clipboard)), at = lastMouse || map.getCenter();
  b.lat = at.lat; b.lng = at.lng;
  state.buildings.push(b); save(); renderBuildings(); updateStats();
  selectBuilding(b, true); flash('Вставлено');
}

/* ════════════════ STATS / FLAG / MATH / FORMAT ════════════════ */
function updateStats() {
  document.getElementById('stat-area').textContent = fmtArea(state.border ? geodesicArea(state.border.map(p => L.latLng(p[0], p[1]))) : 0);
  const n = state.buildings.length + state.roads.length + state.rails.length + state.paths.length;
  document.getElementById('stat-builds').textContent = `${n} ${plural(n, 'постройка', 'постройки', 'построек')}`;
}
function paintFlag() { const c = document.getElementById('flag'); c.style.background = state.color; c.innerHTML = ICONS.flag || ''; c.style.color = pickContrast(state.color); }
function buildPalette() {
  const pal = document.getElementById('palette'); pal.innerHTML = '';
  FLAG_COLORS.forEach(c => { const s = document.createElement('button'); s.className = 'swatch' + (c === state.color ? ' active' : ''); s.style.background = c; s.style.color = c; s.onclick = () => { state.color = c; save(); paintFlag(); if (territory) territory.setStyle({ color: c, fillColor: c }); buildPalette(); pal.classList.add('hidden'); }; pal.appendChild(s); });
}
function geodesicArea(ll) { const R = 6378137, d2r = Math.PI / 180, n = ll.length; if (n < 3) return 0; let a = 0; for (let i = 0; i < n; i++) { const p1 = ll[i], p2 = ll[(i + 1) % n]; a += (p2.lng - p1.lng) * d2r * (2 + Math.sin(p1.lat * d2r) + Math.sin(p2.lat * d2r)); } return Math.abs(a * R * R / 2); }
function pathLength(ll) { let d = 0; for (let i = 1; i < ll.length; i++) d += map.distance(ll[i - 1], ll[i]); return d; }
function fmtArea(m2) { if (m2 <= 0) return '0 км²'; if (m2 < 1e6) return Math.round(m2).toLocaleString('ru-RU') + ' м²'; const km = m2 / 1e6; return km.toLocaleString('ru-RU', { maximumFractionDigits: km < 10 ? 2 : km < 100 ? 1 : 0 }) + ' км²'; }
function fmtLen(m) { return m < 1000 ? Math.round(m) + ' м' : (m / 1000).toLocaleString('ru-RU', { maximumFractionDigits: 2 }) + ' км'; }
function plural(n, a1, a2, a5) { const a = n % 10, b = n % 100; if (a === 1 && b !== 11) return a1; if (a >= 2 && a <= 4 && (b < 10 || b >= 20)) return a2; return a5; }
function pickContrast(hex) { const c = hex.replace('#', ''), r = parseInt(c.substr(0, 2), 16), g = parseInt(c.substr(2, 2), 16), b = parseInt(c.substr(4, 2), 16); return (r * 299 + g * 587 + b * 114) / 1000 > 150 ? '#1a0f0a' : '#fff'; }

/* ════════════════ LOCATE / FILE ════════════════ */
function locate() {
  if (state.border && state.border.length) map.fitBounds(L.polygon(state.border).getBounds(), { padding: [60, 60] });
  else if (state.buildings.length) map.fitBounds(L.latLngBounds(state.buildings.map(b => [b.lat, b.lng])), { padding: [80, 80], maxZoom: 17 });
}
function exportFile() {
  const blob = new Blob([JSON.stringify(state, null, 2)], { type: 'application/json' }), a = document.createElement('a');
  a.href = URL.createObjectURL(blob); a.download = ((state.name || 'ghostnation').replace(/[^\wа-яё \-]/gi, '').trim() || 'ghostnation') + '.json';
  document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 1000); flash('Сохранено в файл');
}
function importFile(file) { const r = new FileReader(); r.onload = () => { try { state = Object.assign(freshState(), JSON.parse(r.result)); undoStack = []; save(); deselect(); document.getElementById('state-name').value = state.name; buildPalette(); renderAll(); locate(); flash('Государство загружено'); } catch (e) { flash('Не удалось прочитать файл', true); } }; r.readAsText(file); }
let flashTimer = null;
function flash(msg, bad) { const t = document.getElementById('toast'); t.textContent = msg; t.style.color = bad ? '#E0245E' : ''; t.classList.remove('hidden'); clearTimeout(flashTimer); flashTimer = setTimeout(() => t.classList.add('hidden'), 1800); }

/* ════════════════ WIRING ════════════════ */
function wire() {
  document.querySelectorAll('.tool[data-tool]').forEach(b => { const t = b.dataset.tool; b.innerHTML = ICONS[t === 'erase' ? 'trash' : t] || ''; b.onclick = () => setTool(t); });
  const map_ = { undo: ICONS.undo, save: ICONS.download, load: ICONS.upload };
  document.querySelector('[data-action="undo"]').innerHTML = map_.undo || ''; document.querySelector('[data-action="undo"]').onclick = undo;
  document.querySelector('[data-action="save"]').innerHTML = map_.save || ''; document.querySelector('[data-action="save"]').onclick = exportFile;
  document.querySelector('[data-action="load"]').innerHTML = map_.load || ''; document.querySelector('[data-action="load"]').onclick = () => document.getElementById('import-file').click();
  document.getElementById('import-file').onchange = e => { if (e.target.files[0]) importFile(e.target.files[0]); e.target.value = ''; };
  document.getElementById('locate').innerHTML = ICONS.target || ''; document.getElementById('locate').onclick = locate;
  document.getElementById('draw-undo').onclick = undoVertex;
  document.getElementById('draw-done').onclick = finishDraw;
  document.getElementById('draw-cancel').onclick = () => { cancelDraw(); setToolIdle(); };
  document.getElementById('edit-del').onclick = () => { if (selected) removeBuilding(selected); };
  document.getElementById('edit-done').onclick = deselect;
  document.getElementById('edit-collapse').onclick = () => document.getElementById('edit').classList.toggle('collapsed');
  document.getElementById('gen-ok').onclick = confirmGen;
  document.getElementById('gen-cancel').onclick = endGenSelect;
  const nameEl = document.getElementById('state-name'); nameEl.value = state.name; nameEl.oninput = () => { state.name = nameEl.value.trim(); save(); };
  document.getElementById('flag').onclick = () => document.getElementById('palette').classList.toggle('hidden');
  document.querySelectorAll('.layer').forEach(b => { b.onclick = () => { const id = b.dataset.layer; if (id === currentLayer) return; map.removeLayer(layers[currentLayer]); layers[id].addTo(map); currentLayer = id; document.querySelectorAll('.layer').forEach(x => x.classList.toggle('active', x === b)); }; });
  document.addEventListener('keydown', e => {
    const k = e.key.toLowerCase();
    if ((e.ctrlKey || e.metaKey) && k === 's') { e.preventDefault(); exportFile(); }
    else if ((e.ctrlKey || e.metaKey) && k === 'z') { e.preventDefault(); undo(); }
    else if ((e.ctrlKey || e.metaKey) && k === 'c') { copySel(); }
    else if ((e.ctrlKey || e.metaKey) && k === 'v') { e.preventDefault(); paste(); }
    else if (e.key === 'Enter' && draw.active) finishDraw();
    else if (e.key === 'Delete' && selected) removeBuilding(selected);
    else if (e.key === 'Escape') { closeCtxMenu(); if (genSel.active) endGenSelect(); else if (draw.active) { cancelDraw(); setToolIdle(); } else if (selected) deselect(); else document.getElementById('palette').classList.add('hidden'); }
    else if (e.key === 'Backspace' && draw.active) { e.preventDefault(); undoVertex(); }
  });
}

/* ════════════════ BOOT ════════════════ */
(async function boot() {
  if (typeof L === 'undefined') { document.body.insertAdjacentHTML('beforeend', '<div style="position:fixed;inset:0;display:grid;place-items:center;background:#000;color:#fff;font:16px sans-serif;text-align:center;padding:24px">Не удалось загрузить Leaflet с CDN.<br>Проверь интернет/туннель и обнови страницу.</div>'); return; }
  await loadIcons();
  initMap();
  roadLayer = L.layerGroup().addTo(map);
  pathLayer = L.layerGroup().addTo(map);
  railLayer = L.layerGroup().addTo(map);
  crossLayer = L.layerGroup().addTo(map);
  buildLayer = L.layerGroup().addTo(map);
  editLayer = L.layerGroup().addTo(map);
  buildPalette(); wire(); renderAll();
})();
