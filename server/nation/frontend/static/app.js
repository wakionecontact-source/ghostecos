/* ════════════════════════════════════════════════════════════
   GhostNation — основай своё государство на спутниковой карте
   Личная песочница. Автосейв localStorage + экспорт/импорт файла.
   ════════════════════════════════════════════════════════════ */

const STORE_KEY = 'ghostnation:v1';
const FLAG_COLORS = ['#D97757', '#E0245E', '#F5A623', '#F8E71C', '#7ED321', '#50E3C2', '#4A90E2', '#9013FE', '#FFFFFF', '#15C26B'];
const DEF = { house: { w: 13, h: 10 }, shop: { w: 13, h: 10 }, tree: { r: 3.5 } };
const ROOF = { house: { fill: '#36b24a', edge: '#0b2c16' }, shop: { fill: '#2E7FE0' } };
const LINE_M = { road: 7, rail: 7, path: 1, alley: 4 };   // ширина на земле, метры
const SNAP_PX = 14;
const PORCH = '#ffce86';
const PORCH_DEPTH = 1.8, BUILD_GAP = 1.5;        // крыльцо считается частью здания
const SIDEWALK_OFF = LINE_M.road / 2 + 1;        // тротуар вдоль дороги (от центра)

const clampWH = v => Math.min(100, Math.max(1, v));
const clampR  = v => Math.min(50, Math.max(1, v));
const rand    = (a, b) => a + Math.random() * (b - a);
const randInt = n => Math.floor(Math.random() * n);

function freshState() {
  return { name: '', color: FLAG_COLORS[0], border: null, buildings: [], roads: [], rails: [], paths: [], alleys: [], districts: [], lights: [], roadWalk: {}, noZebra: [], crosswalks: [], view: { lat: 55.7512, lng: 37.6184, zoom: 12 } };
}
const roadKey = pts => `${pts[0][0].toFixed(5)},${pts[0][1].toFixed(5)}|${pts[pts.length - 1][0].toFixed(5)},${pts[pts.length - 1][1].toFixed(5)}`;
function migrate(s) {
  s.roadWalk = s.roadWalk || {}; s.lights = s.lights || []; s.noZebra = s.noZebra || []; s.crosswalks = s.crosswalks || []; s.districts = s.districts || [];
  const okPt = p => Array.isArray(p) && isFinite(p[0]) && isFinite(p[1]);
  const cleanLn = l => (Array.isArray(l) ? l.filter(okPt) : []);
  ['roads', 'rails', 'paths', 'alleys'].forEach(k => { s[k] = (s[k] || []).map(cleanLn).filter(l => l.length >= 2); });   // выкинуть битые точки/вырожденные линии
  s.buildings = (s.buildings || []).filter(b => b && isFinite(b.lat) && isFinite(b.lng));                                  // выкинуть постройки с битыми координатами (ломали сим и рендер)
  s.lights = s.lights.filter(l => l && isFinite(l.lat) && isFinite(l.lng));
  s.roads.forEach(r => { const k = roadKey(r); if (!(k in s.roadWalk)) s.roadWalk[k] = 'both'; });
  return s;
}
let state = load();
function load() { try { const r = localStorage.getItem(STORE_KEY); if (r) return migrate(Object.assign(freshState(), JSON.parse(r))); } catch (e) { console.warn(e); } return freshState(); }
function save() { try { localStorage.setItem(isMP() ? MP_STORE : STORE_KEY, JSON.stringify(state)); } catch (e) { console.warn(e); } if (isMP()) mpSyncSave(); }

/* ════════════════ UNDO ════════════════ */
let undoStack = [];
function pushUndo() { undoStack.push(JSON.stringify(state)); if (undoStack.length > 60) undoStack.shift(); updateUndoBtn(); }
function undo() {
  if (!undoStack.length) return;
  state = Object.assign(freshState(), JSON.parse(undoStack.pop()));
  save(); deselect(); clearHover();
  document.getElementById('state-name').value = state.name; buildPalette(); renderAll();
  if (borderEdit.active) { if (state.border && state.border.length >= 3) bBuildHandles(); else exitBorderEdit(); }   // правка границы: ручки на новый массив (иначе orphaned)
  updateUndoBtn();
}
function updateUndoBtn() { const b = document.querySelector('[data-action="undo"]'); if (b) b.disabled = undoStack.length === 0; }

/* ════════════════ ICONS ════════════════ */
const ICON_NAMES = ['borders', 'house', 'shop', 'road', 'alley', 'rail', 'path', 'tree', 'district', 'light', 'crosswalk', 'car', 'select', 'trash', 'flag', 'target', 'download', 'upload', 'undo'];
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
let buildLayer, roadLayer, pathLayer, railLayer, crossLayer, editLayer, alleyLayer, districtLayer, zebraLayer, lightLayer, countryLabelLayer;
let layers = {}, currentLayer = 'esri', lastMouse = null;

function initMap() {
  map = L.map('map', { zoomControl: false, attributionControl: true, worldCopyJump: true, maxZoom: 22, zoomSnap: 0, zoomDelta: 0.9, wheelPxPerZoomLevel: 45, zoomAnimation: true }).setView([state.view.lat, state.view.lng], state.view.zoom);   // zoomSnap:0 — плавный зум без рывков; maxZoom 22 — можно ближе
  [['pane-territory', 410], ['pane-district', 412], ['pane-path', 415], ['pane-alley', 417], ['pane-lines', 420], ['pane-cross', 425], ['pane-builds', 430], ['pane-edit', 440]]
    .forEach(([n, z]) => { map.createPane(n); map.getPane(n).style.zIndex = z; });
  L.control.zoom({ position: 'topright' }).addTo(map);
  layers.esri = L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', { maxZoom: 22, maxNativeZoom: 19, attribution: 'Esri · GhostNation' });   // апскейл тайлов выше 19 — можно подъехать вплотную
  layers.google = L.tileLayer('https://mt{s}.google.com/vt/lyrs=s&x={x}&y={y}&z={z}', { maxZoom: 22, maxNativeZoom: 20, subdomains: ['0', '1', '2', '3'], attribution: 'Google · GhostNation' });
  layers[currentLayer].addTo(map);
  map.on('moveend', () => { if (sim.follow) return; if (isMP()) { mpLoadWorld(); return; } const c = map.getCenter(); state.view = { lat: c.lat, lng: c.lng, zoom: map.getZoom() }; save(); });
  map.on('zoomend', () => { [roadLayer, alleyLayer, pathLayer, railLayer].forEach(g => g && g.eachLayer(l => { if (l._mWidth != null) l.setStyle({ weight: Math.max(1, mToPx(l._mWidth)) }); })); renderCountryLabels(); });
  map.on('click', onMapClick);
  map.on('mousemove', e => { lastMouse = e.latlng; onMapMove(e); });
}

/* ════════════════ TOOLS ════════════════ */
let activeTool = null;
function setTool(tool) {
  if (draw.active) cancelDraw();
  if (genSel.active) endGenSelect();
  if (borderEdit.active) exitBorderEdit();
  closeCtxMenu(); closeWalkBar();
  deselect(); clearHover();
  activeTool = (activeTool === tool) ? null : tool;
  document.querySelectorAll('.tool[data-tool]').forEach(b => b.classList.toggle('active', b.dataset.tool === activeTool));
  const m = document.getElementById('map');
  m.classList.toggle('drawing', ['house', 'shop', 'tree', 'light', 'crosswalk'].includes(activeTool));
  m.classList.toggle('erasing', activeTool === 'erase');
  m.classList.toggle('selecting', activeTool === 'select');
  if (activeTool === 'borders') { if (state.border && state.border.length >= 3) editBorder(); else startDraw('borders'); }   // граница есть → редактируем, нет → рисуем
  else if (['road', 'rail', 'path', 'alley', 'district'].includes(activeTool)) startDraw(activeTool);
}
function setToolIdle() { activeTool = null; document.querySelectorAll('.tool[data-tool]').forEach(b => b.classList.remove('active')); document.getElementById('map').classList.remove('drawing', 'erasing', 'selecting'); }

/* ════════════════ DRAW ENGINE ════════════════ */
const draw = { active: false, mode: null, points: [], preview: null, rubber: null, handles: [] };
const LINE_STYLE = { road: '#fff', rail: '#d0d0d0', path: '#e9dec6', alley: '#cfcfcf' };
function startDraw(mode) {
  draw.active = true; draw.mode = mode; draw.points = []; draw.handles = [];
  if (mode === 'borders') draw.preview = L.polygon([], { pane: 'pane-territory', color: state.color, weight: 2.5, fillColor: state.color, fillOpacity: .15, dashArray: '6 5' }).addTo(map);
  else if (mode === 'district') draw.preview = L.polygon([], { pane: 'pane-district', color: '#F5A623', weight: 2, fillColor: '#F5A623', fillOpacity: .15, dashArray: '6 5' }).addTo(map);
  else draw.preview = L.polyline([], { pane: 'pane-lines', color: LINE_STYLE[mode], weight: mode === 'path' ? 3 : 4, dashArray: '6 6' }).addTo(map);
  draw.rubber = L.polyline([], { pane: 'pane-lines', color: state.color, weight: 1.6, opacity: .7, dashArray: '4 5', interactive: false }).addTo(map);
  document.getElementById('map').classList.add('drawing');
  document.getElementById('draw-bar').classList.remove('hidden');
  updateDrawHint();
}
function addVertex(latlng) {
  let snapped = false;
  if (draw.mode === 'road' || draw.mode === 'rail' || draw.mode === 'alley') { const s = snapLine(latlng); if (s) { latlng = s; snapped = true; } }
  else if (draw.mode === 'path') { const s = snapPath(latlng); if (s) { latlng = s; snapped = true; } }
  draw.points.push(latlng);
  draw.handles.push(L.marker(latlng, { pane: 'markerPane', interactive: false, keyboard: false, icon: L.divIcon({ className: '', html: `<div class="vertex-dot${snapped ? ' snapped' : ''}"></div>`, iconSize: [12, 12], iconAnchor: [6, 6] }) }).addTo(map));
  draw.preview.setLatLngs(draw.points);
  updateDrawHint();
}
function onMapMove(e) { if (draw.active && draw.points.length) draw.rubber.setLatLngs([draw.points[draw.points.length - 1], e.latlng]); }
function undoVertex() { if (!draw.points.length) return; draw.points.pop(); const h = draw.handles.pop(); if (h) map.removeLayer(h); draw.preview.setLatLngs(draw.points); if (!draw.points.length) draw.rubber.setLatLngs([]); updateDrawHint(); }
function finishDraw() {
  const min = (draw.mode === 'borders' || draw.mode === 'district') ? 3 : 2;
  if (draw.points.length < min) return;
  const pts = draw.points.map(p => [p.lat, p.lng]);
  if (draw.mode === 'district') {
    if (!state.border) { flash('Сначала проведи границы страны', true); return; }
    if (!pts.every(p => pointInPoly(p[0], p[1], state.border))) { flash('Район — только внутри границ', true); return; }
  }
  pushUndo();
  if (draw.mode === 'borders') { state.border = pts; renderTerritory(); if (isMP()) mpClaim(); }
  else if (draw.mode === 'road') { state.roads.push(pts); state.roadWalk[roadKey(pts)] = 'none'; renderRoads(); renderCrossings(); renderZebras(); openWalkBar(pts); }
  else if (draw.mode === 'rail') { state.rails.push(pts); renderRails(); renderCrossings(); }
  else if (draw.mode === 'alley') { state.alleys.push(pts); state.roadWalk[roadKey(pts)] = 'none'; renderAlleys(); openWalkBar(pts); }
  else if (draw.mode === 'district') { state.districts.push({ pts, color: FLAG_COLORS[randInt(FLAG_COLORS.length)] }); renderDistricts(); }
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
  if (draw.mode === 'borders' || draw.mode === 'district') { done.disabled = n < 3; hint.textContent = `${draw.mode === 'district' ? 'Район' : 'Граница'}: ${n} ${plural(n, 'точка', 'точки', 'точек')}` + (n >= 3 ? ' · ~' + fmtArea(geodesicArea(draw.points)) : ''); }
  else { const lbl = draw.mode === 'rail' ? 'Жд' : draw.mode === 'path' ? 'Тропинка' : draw.mode === 'alley' ? 'Переулок' : 'Дорога'; done.disabled = n < 2; hint.textContent = `${lbl}: ${n} ${plural(n, 'точка', 'точки', 'точек')}` + (n >= 2 ? ' · ' + fmtLen(pathLength(draw.points)) : ''); }
}

/* ════════════════ SNAP ════════════════ */
function projSeg(p, a, b) { const dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy; if (l2 === 0) return a; let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2; t = Math.max(0, Math.min(1, t)); return L.point(a.x + t * dx, a.y + t * dy); }
function snapLine(latlng) {            // снап к дорогам/жд/переулкам: ВЕРШИНЫ приоритетно и с бóльшим радиусом → чистые стыки
  const p = map.latLngToLayerPoint(latlng), lines = state.roads.concat(state.rails, state.alleys);
  let bestV = null, bestVD = SNAP_PX * 1.7;            // 1) ближайшая ВЕРШИНА (концы «прилипают» точно → ровные перекрёстки)
  for (const line of lines) for (let i = 0; i < line.length; i++) {
    const v = map.latLngToLayerPoint(L.latLng(line[i][0], line[i][1])), d = p.distanceTo(v);
    if (d < bestVD) { bestVD = d; bestV = L.latLng(line[i][0], line[i][1]); }
  }
  if (bestV) return bestV;
  let best = null, bestD = SNAP_PX;                    // 2) иначе — проекция на ближайший сегмент (T точно НА дорогу)
  for (const line of lines) for (let i = 1; i < line.length; i++) {
    const a = map.latLngToLayerPoint(L.latLng(line[i - 1][0], line[i - 1][1])), b = map.latLngToLayerPoint(L.latLng(line[i][0], line[i][1])), pr = projSeg(p, a, b);
    if (p.distanceTo(pr) < bestD) { bestD = p.distanceTo(pr); best = map.layerPointToLatLng(pr); }
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
function nearestRoad(lat, lng) {        // ближайшая УЛИЦА (дорога ИЛИ переулок) + bearing — дорожки/ориентация ведутся к ней
  const p = map.latLngToLayerPoint(L.latLng(lat, lng)); let best = null, bestD = Infinity;
  for (const road of state.roads.concat(state.alleys)) for (let i = 1; i < road.length; i++) {
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
  if (sim.on && !activeTool && !draw.active && !genSel.active) {     // клик по жителю → выбор + слежение
    const hit = pickCitizen(e.containerPoint);
    if (hit) { selectCitizen(hit); return; }
    if (sim.selected) { deselectCitizen(); return; }
  }
  if (genSel.active) return;
  if (draw.active) { addVertex(e.latlng); return; }
  if (activeTool === 'select') { deselect(); return; }
  if (activeTool === 'light') {
    const X = nearestIntersection(e.latlng);
    if (!X) { flash('Светофор ставится на перекрёстке', true); return; }
    if (!state.lights.some(l => distMeters(l.lat, l.lng, X[0], X[1]) < 2)) { pushUndo(); state.lights.push({ lat: X[0], lng: X[1] }); save(); renderLights(); }
    return;
  }
  if (activeTool === 'crosswalk') {
    const info = nearestRoad(e.latlng.lat, e.latlng.lng);
    let lat = e.latlng.lat, lng = e.latlng.lng, ang = 0;
    if (info && distMeters(lat, lng, info.lat, info.lng) <= 25) { lat = info.lat; lng = info.lng; ang = info.bearing * Math.PI / 180; }   // снап на дорогу, поперёк неё
    pushUndo(); state.crosswalks.push({ lat, lng, ang }); save(); renderZebras();
    return;
  }
  if (['house', 'shop', 'tree'].includes(activeTool)) placeBuilding(activeTool, e.latlng);
}
function bRadius(b) { return b.type === 'tree' ? clampR(b.r ?? DEF.tree.r) : Math.hypot(clampWH(b.w ?? DEF[b.type].w) / 2, clampWH(b.h ?? DEF[b.type].h) / 2); }
function distMeters(la1, ln1, la2, ln2) { const E = (ln2 - ln1) * mPerDegLng(la1), N = (la2 - la1) * MPD_LAT; return Math.hypot(E, N); }
function overlapsAt(lat, lng, radius, exclude) { for (const o of state.buildings) { if (o === exclude) continue; if (distMeters(lat, lng, o.lat, o.lng) < radius + bRadius(o)) return true; } return false; }
function insideBuilding(lat, lng) { for (const o of state.buildings) if (distMeters(lat, lng, o.lat, o.lng) < bRadius(o) + 1) return true; return false; }
function freeSpot(lat, lng, radius) {
  for (let ring = 1; ring <= 9; ring++) { const dist = ring * (radius * 2 + 3); for (let k = 0; k < 8; k++) { const ang = k / 8 * 2 * Math.PI, ll = offset(lat, lng, Math.cos(ang) * dist, Math.sin(ang) * dist); if (!overlapsAt(ll[0], ll[1], radius) && nearestRoadDist(ll[0], ll[1]) >= LINE_M.road / 2 + radius * 0.7) return { lat: ll[0], lng: ll[1] }; } }
  return { lat, lng };
}
function pointSegDistM(plat, plng, a, b) {     // metres from point to road segment
  const mlng = mPerDegLng(a[0]), bx = (b[1] - a[1]) * mlng, by = (b[0] - a[0]) * MPD_LAT;
  const px = (plng - a[1]) * mlng, py = (plat - a[0]) * MPD_LAT, l2 = bx * bx + by * by;
  let t = l2 ? (px * bx + py * by) / l2 : 0; t = Math.max(0, Math.min(1, t));
  return Math.hypot(px - t * bx, py - t * by);
}
function buildingHitsRoad(b) {                  // any corner / porch within road half-width of any road
  if (b.type === 'tree') return nearestRoadDist(b.lat, b.lng) < LINE_M.road / 2 + clampR(b.r ?? DEF.tree.r) * 0.6;   // у дерева нет w/h — проверяем кругом (иначе rectCorners=NaN и дерево лезло на дорогу)
  const pts = [[b.lat, b.lng], ...rectCorners(b)]; const dr = doorRect(b); pts.push(dr[2], dr[3]);
  for (const road of state.roads) for (let i = 1; i < road.length; i++)
    for (const p of pts) if (pointSegDistM(p[0], p[1], road[i - 1], road[i]) < LINE_M.road / 2 + 0.3) return true;
  return false;
}
function nearestRoadDist(lat, lng) { let best = Infinity; for (const road of state.roads) for (let i = 1; i < road.length; i++) best = Math.min(best, pointSegDistM(lat, lng, road[i - 1], road[i])); return best; }
function pushOffRoad(b) {                        // сдвинуть здание перпендикулярно прочь от ближайшей дороги, пока не съедет с неё
  for (let t = 0; t < 12 && buildingHitsRoad(b); t++) {
    const info = nearestRoad(b.lat, b.lng); if (!info) break;
    const E = (b.lng - info.lng) * mPerDegLng(b.lat), N = (b.lat - info.lat) * MPD_LAT, d = Math.hypot(E, N) || 1;
    const ll = offset(b.lat, b.lng, E / d * 2, N / d * 2); b.lat = ll[0]; b.lng = ll[1];
  }
}
function placeBuilding(type, latlng) {
  pushUndo();
  const b = { type, lat: latlng.lat, lng: latlng.lng };
  if (type === 'tree') {
    b.r = DEF.tree.r;
    if (overlapsAt(b.lat, b.lng, b.r, b) || buildingHitsRoad(b)) { const f = freeSpot(b.lat, b.lng, b.r); b.lat = f.lat; b.lng = f.lng; }
  } else {
    if (insideBuilding(b.lat, b.lng)) { const f = freeSpot(b.lat, b.lng, 9); b.lat = f.lat; b.lng = f.lng; }
    b.w = Math.round(rand(9, 18)); b.h = Math.round(rand(9, 15));    // умеренный размер, не «очень большой»
    alignToRoad(b);
    pushOffRoad(b); alignToRoad(b);                                  // не на дороге, вход к дороге
    for (let t = 0; t < 10 && overlapsAt(b.lat, b.lng, bRadius(b), b); t++) {
      if (Math.max(b.w, b.h) > 9) { b.w = Math.max(9, Math.round(b.w * 0.85)); b.h = Math.max(9, Math.round(b.h * 0.85)); }
      else { const f = freeSpot(b.lat, b.lng, bRadius(b)); b.lat = f.lat; b.lng = f.lng; pushOffRoad(b); alignToRoad(b); }
    }
    addWalkway(b);                                                   // дорожка к дороге, если рядом
  }
  state.buildings.push(b); save(); renderBuildings(); renderPaths(); updateStats();
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
function addWalkway(b) {                 // дорожка от крыльца к тротуару ближайшей дороги
  const info = nearestRoad(b.lat, b.lng); if (!info) return;
  if (distMeters(b.lat, b.lng, info.lat, info.lng) > 80) return;   // далеко от дороги — без дорожки
  const dr = doorRect(b), ent = [(dr[2][0] + dr[3][0]) / 2, (dr[2][1] + dr[3][1]) / 2];
  const a = info.bearing * Math.PI / 180; let pE = -Math.sin(a), pN = Math.cos(a);
  const tE = (b.lng - info.lng) * mPerDegLng(b.lat), tN = (b.lat - info.lat) * MPD_LAT;
  if (pE * tE + pN * tN < 0) { pE = -pE; pN = -pN; }
  state.paths.push([ent, offset(info.lat, info.lng, pE * SIDEWALK_OFF, pN * SIDEWALK_OFF)]);
}
function runGeneration(pairs, zone) {
  pushUndo();
  const stepM = 20;
  let shops = 0; const made = [];
  pairs.forEach(([road, si, pside]) => {
    const a = road[si], b = road[si + 1], lat = a[0];
    const E = (b[1] - a[1]) * mPerDegLng(lat), N = (b[0] - a[0]) * MPD_LAT, len = Math.hypot(E, N);
    if (len < 8) return;
    const ux = E / len, uy = N / len, px = -uy, py = ux, bearing = Math.round(Math.atan2(N, E) * 180 / Math.PI);
    const sides = pside === 'left' ? [1] : pside === 'right' ? [-1] : [1, -1];   // сторона застройки участка
    for (let d = stepM / 2; d < len - 2; d += stepM) {
      const cy = a[0] + uy * d / MPD_LAT, cx = a[1] + ux * d / mPerDegLng(lat);
      for (const sd of sides) {
        const w = Math.round(rand(9, 18)), h = Math.round(rand(9, 16));
        const c = LINE_M.road / 2 + PORCH_DEPTH + BUILD_GAP + h / 2 + rand(0, 7);   // чуть дальше, не впритык и вразнобой
        const isShop = zone === 'commercial' ? true : zone === 'pureRes' ? false : Math.random() < 0.13 / (1 + shops * 1.3);   // зона: торговая=всё, без магазинов=ничего, жилая=редко
        const nb = { type: isShop ? 'shop' : 'house', lat: cy + py * c * sd / MPD_LAT, lng: cx + px * c * sd / mPerDegLng(cy), w, h, rot: bearing };
        setDoorToward(nb, cy, cx);
        if (!overlapsAt(nb.lat, nb.lng, bRadius(nb)) && !buildingHitsRoad(nb)) {
          state.buildings.push(nb); made.push(nb); if (isShop) shops++; addWalkway(nb);
        }
      }
    }
  });
  if (zone === 'res' && shops === 0) { const hs = made.filter(b => b.type === 'house'); if (hs.length) hs[randInt(hs.length)].type = 'shop'; }  // жилая: минимум 1 магазин
  save(); renderBuildings(); renderPaths(); updateStats(); flash(`Застройка: +${made.length}`);
}

/* ════════════════ ROAD CONTEXT MENU + SEGMENT SELECTION ════════════════ */
let genSel = { active: false, segs: null, side: 'both', layer: null, zone: 'res' };   // segs = Set ключей "ri:si"; side — общая сторона застройки
const streets = () => state.roads.concat(state.alleys);   // дороги И переулки — авто-застройка/меню работают по обоим
function updateGenSideBtn() { const b = document.getElementById('gen-side'); if (b) b.textContent = 'Сторона: ' + (genSel.side === 'left' ? 'слева' : genSel.side === 'right' ? 'справа' : 'обе'); }
function closeCtxMenu() { const m = document.getElementById('ctx-menu'); if (m) m.classList.add('hidden'); }
function openRoadMenu(e, road) {
  closeCtxMenu();
  const m = document.getElementById('ctx-menu'); m.innerHTML = '';
  [['Авто-застройка вдоль дороги', () => { closeCtxMenu(); startGenSelect(road); }],
   ['Тротуар (пешеходы)…', () => { closeCtxMenu(); openWalkBar(road); }],
   ['Подтянуть здания к дороге', () => { closeCtxMenu(); settleAll(); }]]
    .forEach(([label, fn]) => { const btn = document.createElement('button'); btn.className = 'ctx-item'; btn.textContent = label; btn.onclick = fn; m.appendChild(btn); });
  const o = e.originalEvent;
  m.classList.remove('hidden');
  m.style.left = Math.min(window.innerWidth - m.offsetWidth - 8, o.clientX) + 'px';
  m.style.top = Math.min(window.innerHeight - m.offsetHeight - 8, o.clientY) + 'px';
}
function startGenSelect(road) {
  genSel.active = true; genSel.segs = new Set(); genSel.side = 'both'; genSel.zone = 'res';
  document.querySelectorAll('[data-zone]').forEach(x => x.classList.toggle('active', x.dataset.zone === 'res'));
  genSel.layer = L.layerGroup().addTo(map);
  drawGenSegs(); updateGenSideBtn();   // ничего не пред-выбрано — юзер кликает по улицам, что застроить
  document.getElementById('gen-bar').classList.remove('hidden');
  document.getElementById('map').classList.add('selecting');
}
function drawGenSegs() {                          // сегменты ВСЕХ дорог; клик циклит обе→лево→право→выкл
  genSel.layer.clearLayers();
  const w = Math.max(11, mToPx(LINE_M.road));   // ШИРОКАЯ кликабельная линия (с дорогу) — легко попасть, удобно жать
  streets().forEach((road, ri) => {
    for (let si = 0; si < road.length - 1; si++) {
      const key = ri + ':' + si, on = genSel.segs.has(key), seg = [road[si], road[si + 1]];
      const tog = ev => { L.DomEvent.stop(ev); genSel.segs.has(key) ? genSel.segs.delete(key) : genSel.segs.add(key); drawGenSegs(); };   // клик = включить/выключить участок
      L.polyline(seg, { pane: 'pane-edit', color: on ? '#D97757' : '#9aa0a6', weight: w, opacity: on ? .5 : .26, lineCap: 'round' }).addTo(genSel.layer).on('click', tog);
      if (on && genSel.side !== 'both') { const off = (genSel.side === 'left' ? 1 : -1) * (SIDEWALK_OFF + 4); L.polyline(offsetLine(seg, off), { pane: 'pane-edit', color: '#D97757', weight: Math.max(5, w * 0.45), opacity: .92, lineCap: 'round', interactive: false }).addTo(genSel.layer); }
    }
  });
}
function endGenSelect() { genSel.active = false; if (genSel.layer) { map.removeLayer(genSel.layer); genSel.layer = null; } genSel.segs = null; document.getElementById('gen-bar').classList.add('hidden'); document.getElementById('map').classList.remove('selecting'); }
function confirmGen() {
  const S = streets(); const pairs = (genSel.segs ? [...genSel.segs] : []).map(k => { const [ri, si] = k.split(':').map(Number); return [S[ri], si, genSel.side]; }).filter(p => p[0]);
  const zone = genSel.zone || 'res';
  endGenSelect();
  if (pairs.length) runGeneration(pairs, zone);
}

/* ════════════════ SIDEWALK SIDE BAR ════════════════ */
let walkBarKey = null;
function openWalkBar(pts) { walkBarKey = roadKey(pts); const cur = state.roadWalk[walkBarKey] || 'both'; document.getElementById('walk-bar').classList.remove('hidden'); document.querySelectorAll('[data-walk]').forEach(x => x.classList.toggle('active', x.dataset.walk === cur)); }
function closeWalkBar() { document.getElementById('walk-bar').classList.add('hidden'); walkBarKey = null; }

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

/* ── РЕДАКТИРОВАНИЕ ГРАНИЦЫ: тяни вершины · средние точки добавляют · ПКМ удаляет ── */
const borderEdit = { active: false, verts: [], mids: [] };
function bMidPos(i) { const B = state.border, a = B[i], b = B[(i + 1) % B.length]; return [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]; }
function bPositionMids() { borderEdit.mids.forEach((m, i) => m.setLatLng(bMidPos(i))); }
function bClearHandles() { borderEdit.verts.forEach(m => map.removeLayer(m)); borderEdit.mids.forEach(m => map.removeLayer(m)); borderEdit.verts = []; borderEdit.mids = []; }
function bBuildHandles() {
  bClearHandles(); const B = state.border; if (!B) return;
  B.forEach((pt, i) => {                                  // вершины — тянуть
    const m = L.marker(pt, { pane: 'markerPane', draggable: true, icon: L.divIcon({ className: '', html: '<div class="edit-handle h-vert"></div>', iconSize: [15, 15], iconAnchor: [7.5, 7.5] }) }).addTo(map);
    m.on('dragstart', () => pushUndo());
    m.on('drag', e => { B[i] = [e.latlng.lat, e.latlng.lng]; if (territory) territory.setLatLngs(B); bPositionMids(); });
    m.on('dragend', () => { save(); updateStats(); });
    m.on('contextmenu', e => { L.DomEvent.stop(e); if (B.length > 3) { pushUndo(); B.splice(i, 1); save(); renderTerritory(); bBuildHandles(); updateStats(); } else flash('Минимум 3 точки', true); });
    borderEdit.verts.push(m);
  });
  B.forEach((pt, i) => {                                  // средние точки — потяни, чтобы добавить вершину
    const m = L.marker(bMidPos(i), { pane: 'markerPane', draggable: true, icon: L.divIcon({ className: '', html: '<div class="edit-handle h-mid"></div>', iconSize: [12, 12], iconAnchor: [6, 6] }) }).addTo(map);
    m.on('dragstart', () => pushUndo());
    m.on('drag', e => { const tmp = B.slice(); tmp.splice(i + 1, 0, [e.latlng.lat, e.latlng.lng]); if (territory) territory.setLatLngs(tmp); });
    m.on('dragend', e => { B.splice(i + 1, 0, [e.latlng.lat, e.latlng.lng]); save(); renderTerritory(); bBuildHandles(); updateStats(); });
    borderEdit.mids.push(m);
  });
}
function editBorder() { borderEdit.active = true; renderTerritory(); bBuildHandles(); document.getElementById('border-bar').classList.remove('hidden'); }
function exitBorderEdit() { borderEdit.active = false; bClearHandles(); const bar = document.getElementById('border-bar'); if (bar) bar.classList.add('hidden'); save(); if (isMP()) mpClaim(); }

/* ── ТАБЛИЧКИ СТРАН: видны при отдалении, лейбл с названием в центре границы (структура под мультиплеер) ── */
const LABEL_MAX_ZOOM = 14;
function borderCentroid(B) { let lat = 0, lng = 0; for (const p of B) { lat += p[0]; lng += p[1]; } return [lat / B.length, lng / B.length]; }
function countriesForLabels() { return (state.name && state.border && state.border.length >= 3) ? [{ name: state.name, border: state.border, color: state.color }] : []; }   // пока одна страна — игрока; в мультиплеере сюда придут чужие
function escLabel(s) { return String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }
function renderCountryLabels() {
  if (!countryLabelLayer) return;
  countryLabelLayer.clearLayers();
  if (map.getZoom() > LABEL_MAX_ZOOM) return;            // вблизи прячем — не мешает строить
  for (const c of countriesForLabels()) {
    const html = `<div class="country-label" style="--c:${c.color || '#D97757'}">${escLabel(c.name)}</div>`;
    L.marker(borderCentroid(c.border), { pane: 'markerPane', interactive: false, keyboard: false, icon: L.divIcon({ className: 'country-label-wrap', html, iconSize: [0, 0], iconAnchor: [0, 0] }) }).addTo(countryLabelLayer);
  }
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
    const walk = state.roadWalk[roadKey(r)] || 'both';   // none | left | right | both
    const sides = walk === 'both' ? [SIDEWALK_OFF, -SIDEWALK_OFF] : walk === 'left' ? [SIDEWALK_OFF] : walk === 'right' ? [-SIDEWALK_OFF] : [];
    sides.forEach(o => tagW(L.polyline(offsetLine(r, o), { pane: 'pane-path', color: '#b7b9bc', weight: sw, opacity: .92, interactive: false, lineCap: 'round' }).addTo(roadLayer), LINE_M.path + 0.6));   // тротуары по выбранным сторонам
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
function renderAlleys() {                         // переулок: узкий; теперь КАК ДОРОГА — тротуары (по выбору) + меню
  alleyLayer.clearLayers(); const w = Math.max(2, mToPx(LINE_M.alley)), sw = Math.max(2, mToPx(LINE_M.path + 0.6));
  state.alleys.forEach(r => {
    const walk = state.roadWalk[roadKey(r)] || 'none';   // у переулка по умолчанию БЕЗ тротуаров (можно включить в меню)
    const sides = walk === 'both' ? [SIDEWALK_OFF, -SIDEWALK_OFF] : walk === 'left' ? [SIDEWALK_OFF] : walk === 'right' ? [-SIDEWALK_OFF] : [];
    sides.forEach(o => tagW(L.polyline(offsetLine(r, o), { pane: 'pane-path', color: '#b7b9bc', weight: sw, opacity: .9, interactive: false, lineCap: 'round' }).addTo(alleyLayer), LINE_M.path + 0.6));
    const ln = tagW(L.polyline(r, { pane: 'pane-alley', color: '#54585f', weight: w, opacity: .96, lineCap: 'round', lineJoin: 'round' }).addTo(alleyLayer), LINE_M.alley);
    ln.on('click', e => {
      if (activeTool === 'erase') { L.DomEvent.stop(e); eraseSegment('alleys', r, e.latlng); }
      else if (!activeTool && !draw.active && !genSel.active) { L.DomEvent.stop(e); openRoadMenu(e, r); }   // меню: авто-застройка/тротуар/подтянуть
    });
    ln.on('mousemove', e => { if (activeTool === 'erase') hoverSeg(e.latlng, r); });
    ln.on('mouseout', clearHover);
  });
}
function pointInPoly(lat, lng, poly) {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const yi = poly[i][0], xi = poly[i][1], yj = poly[j][0], xj = poly[j][1];
    if (((yi > lat) !== (yj > lat)) && (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi)) inside = !inside;
  }
  return inside;
}
function renderDistricts() {
  districtLayer.clearLayers();
  state.districts.forEach(d => {
    const poly = L.polygon(d.pts, { pane: 'pane-district', color: d.color, weight: 2, opacity: .85, fillColor: d.color, fillOpacity: .14, dashArray: '7 5' }).addTo(districtLayer);
    poly.on('click', e => { if (activeTool !== 'erase') return; L.DomEvent.stop(e); pushUndo(); state.districts = state.districts.filter(x => x !== d); save(); renderDistricts(); updateStats(); });
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
  ({ roads: renderRoads, paths: renderPaths, rails: renderRails, alleys: renderAlleys }[key])();
  renderCrossings(); renderZebras(); updateStats();
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

/* ════════════════ ROAD INTERSECTIONS · ZEBRAS · TRAFFIC LIGHTS ════════════════ */
function roadIntersections() {
  const pts = [];
  for (let a = 0; a < state.roads.length; a++) for (let b = a + 1; b < state.roads.length; b++) {
    const ra = state.roads[a], rb = state.roads[b];
    for (let i = 1; i < ra.length; i++) for (let j = 1; j < rb.length; j++) { const X = segInter(ra[i - 1], ra[i], rb[j - 1], rb[j]); if (X) pts.push(X); }
  }
  for (let a = 0; a < state.roads.length; a++) { const ra = state.roads[a];
    for (const end of [ra[0], ra[ra.length - 1]]) for (let b = 0; b < state.roads.length; b++) { if (b === a) continue; const rb = state.roads[b];
      for (let j = 1; j < rb.length; j++) if (pointSegDistM(end[0], end[1], rb[j - 1], rb[j]) < 6) { pts.push(projOnSegLL(end, rb[j - 1], rb[j])); break; }   // точку примыкания центрируем НА дорогу (если соединено чуть мимо)
    }
  }
  const ded = []; for (const p of pts) if (!ded.some(q => distMeters(p[0], p[1], q[0], q[1]) < 12)) ded.push(p);   // 12 м: неровный стык (точки в ~8 м) схлопываем в ОДИН перекрёсток, иначе зебры от обеих внахлёст
  return ded.filter(p => roadArmsAt(p[0], p[1], LINE_M.road * 1.4) >= 3);   // реальный перекрёсток = ≥3 рукава (T/+/Y), НЕ изгиб дороги (2 рукава)
}
function roadsAt(lat, lng, rad) {
  const dirs = [];
  for (const road of state.roads) for (let i = 1; i < road.length; i++) if (pointSegDistM(lat, lng, road[i - 1], road[i]) < rad) { const E = (road[i][1] - road[i - 1][1]) * mPerDegLng(lat), N = (road[i][0] - road[i - 1][0]) * MPD_LAT; dirs.push(Math.atan2(N, E)); }
  const out = []; for (const a of dirs) { const d = ((a * 180 / Math.PI) % 180 + 180) % 180; if (!out.some(o => { const od = ((o * 180 / Math.PI) % 180 + 180) % 180; const diff = Math.abs(od - d); return Math.min(diff, 180 - diff) < 15; })) out.push(a); } return out;   // дедуп в ГРАДУСАХ (o хранится в радианах — раньше сравнивали рад с град, оси N/S не схлопывались → дубли зебр)
}
const armBearing = (from, to) => Math.atan2((to[0] - from[0]) * MPD_LAT, (to[1] - from[1]) * mPerDegLng(from[0]));
function projOnSegLL(p, a, b) {                  // проекция точки на отрезок (в latlng)
  const m = mPerDegLng(a[0]), bx = (b[1] - a[1]) * m, by = (b[0] - a[0]) * MPD_LAT, px = (p[1] - a[1]) * m, py = (p[0] - a[0]) * MPD_LAT, l2 = bx * bx + by * by;
  let t = l2 ? (px * bx + py * by) / l2 : 0; t = Math.max(0, Math.min(1, t));
  return [a[0] + t * by / MPD_LAT, a[1] + t * bx / m];
}
function roadArmsAt(lat, lng, rad) {            // число «рукавов» дорог из точки: 1 на конце дороги, 2 на проходе/изгибе
  const arms = [];
  for (const road of state.roads) {
    for (let i = 0; i < road.length; i++) if (distMeters(lat, lng, road[i][0], road[i][1]) < rad) {
      if (i > 0) arms.push(armBearing(road[i], road[i - 1]));
      if (i < road.length - 1) arms.push(armBearing(road[i], road[i + 1]));
    }
    for (let i = 1; i < road.length; i++) {     // дорога проходит ЧЕРЕЗ точку (не у вершины) → 2 рукава
      const a = road[i - 1], b = road[i];
      if (pointSegDistM(lat, lng, a, b) < rad && distMeters(lat, lng, a[0], a[1]) > rad && distMeters(lat, lng, b[0], b[1]) > rad) { arms.push(armBearing(a, b)); arms.push(armBearing(b, a)); }
    }
  }
  const uniq = [];
  for (const x of arms) { const d = ((x * 180 / Math.PI) % 360 + 360) % 360; if (!uniq.some(o => { const df = Math.abs(o - d); return Math.min(df, 360 - df) < 22; })) uniq.push(d); }
  return uniq.length;
}
function nearestIntersection(latlng) { let best = null, bestD = 28; for (const X of roadIntersections()) { const d = distMeters(latlng.lat, latlng.lng, X[0], X[1]); if (d < bestD) { bestD = d; best = X; } } return best; }
const dirAligned = (d, ang) => { const df = Math.abs((((d - ang) * 180 / Math.PI) % 180 + 180) % 180); return Math.min(df, 180 - df) < 25; };
function renderZebras() {
  zebraLayer.clearLayers();
  for (const X of roadIntersections()) for (const ang of roadsAt(X[0], X[1], LINE_M.road * 1.4)) drawZebra(X, ang);
  for (const c of state.crosswalks) drawCrosswalk(c);     // ручные переходы (инструмент «Переход»)
}
function drawCrosswalk(c) {                               // одиночный переход, поставленный вручную где угодно
  const ca = Math.cos(c.ang), sa = Math.sin(c.ang), along = 3.6, across = LINE_M.road * 0.92, n = 6;
  for (let s = 0; s < n; s++) {
    const off = -across / 2 + (s + 0.5) * (across / n);
    const p1 = offset(c.lat, c.lng, (along / 2) * ca - off * sa, (along / 2) * sa + off * ca);
    const p2 = offset(c.lat, c.lng, (-along / 2) * ca - off * sa, (-along / 2) * sa + off * ca);
    L.polyline([p1, p2], { pane: 'pane-cross', color: '#f2f2f2', weight: 3, opacity: .95, interactive: false }).addTo(zebraLayer);
  }
  const at = (dl, dw) => offset(c.lat, c.lng, dl * ca - dw * sa, dl * sa + dw * ca);
  const hl = along / 2 + 1, hw = across / 2 + 1, rect = [at(hl, hw), at(hl, -hw), at(-hl, -hw), at(-hl, hw)];
  const hit = L.polygon(rect, { pane: 'pane-cross', stroke: false, fillOpacity: 0 }).addTo(zebraLayer);
  hit.on('click', e => { if (activeTool !== 'erase') return; L.DomEvent.stop(e); pushUndo(); state.crosswalks = state.crosswalks.filter(x => x !== c); save(); renderZebras(); });
  hit.on('mouseover', () => { if (activeTool !== 'erase') return; clearHover(); hoverHL = L.polygon(rect, { pane: 'pane-edit', color: '#E0245E', weight: 2, fill: false, interactive: false }).addTo(map); });
  hit.on('mouseout', clearHover);
}
function drawZebra(X, ang) {                              // переход поперёк дороги, на ПОДХОДАХ (рукавах), не в центре
  const ca = Math.cos(ang), sa = Math.sin(ang), along = 3.2, across = LINE_M.road * 0.82, n = 5, D = LINE_M.road * 0.95;
  for (const arm of [1, -1]) {
    const cen = offset(X[0], X[1], ca * D * arm, sa * D * arm);     // центр перехода на этом плече
    if (!roadsAt(cen[0], cen[1], LINE_M.road * 0.8).some(d => dirAligned(d, ang))) continue;   // на плече нет дороги — нет перехода
    const key = `${X[0].toFixed(5)},${X[1].toFixed(5)}@${Math.round(((ang * 180 / Math.PI) % 180 + 180) % 180)}#${arm}`;
    if (state.noZebra.includes(key)) continue;
    for (let s = 0; s < n; s++) {
      const off = -across / 2 + (s + 0.5) * (across / n);
      const p1 = offset(cen[0], cen[1], (along / 2) * ca - off * sa, (along / 2) * sa + off * ca);
      const p2 = offset(cen[0], cen[1], (-along / 2) * ca - off * sa, (-along / 2) * sa + off * ca);
      L.polyline([p1, p2], { pane: 'pane-cross', color: '#f2f2f2', weight: 3, opacity: .92, interactive: false }).addTo(zebraLayer);
    }
    const at = (dl, dw) => offset(cen[0], cen[1], dl * ca - dw * sa, dl * sa + dw * ca);
    const hl = along / 2 + 1, hw = across / 2 + 1, rect = [at(hl, hw), at(hl, -hw), at(-hl, -hw), at(-hl, hw)];
    const hit = L.polygon(rect, { pane: 'pane-cross', stroke: false, fillOpacity: 0 }).addTo(zebraLayer);
    hit.on('click', e => { if (activeTool !== 'erase') return; L.DomEvent.stop(e); pushUndo(); if (!state.noZebra.includes(key)) state.noZebra.push(key); save(); renderZebras(); });
    hit.on('mouseover', () => { if (activeTool !== 'erase') return; clearHover(); hoverHL = L.polygon(rect, { pane: 'pane-edit', color: '#E0245E', weight: 2, fill: false, interactive: false }).addTo(map); });
    hit.on('mouseout', clearHover);
  }
}
function renderLights() {
  lightLayer.clearLayers();
  state.lights.forEach(l => {
    const m = L.marker([l.lat, l.lng], { pane: 'markerPane', icon: L.divIcon({ className: '', iconSize: [12, 12], iconAnchor: [6, 6], html: '<div class="tl-top"></div>' }) }).addTo(lightLayer);
    m.on('click', e => { if (activeTool !== 'erase') return; L.DomEvent.stop(e); pushUndo(); state.lights = state.lights.filter(x => x !== l); save(); renderLights(); });
  });
}

function renderAll() { renderTerritory(); renderDistricts(); renderRoads(); renderAlleys(); renderPaths(); renderRails(); renderCrossings(); renderZebras(); renderBuildings(); renderLights(); renderCountryLabels(); updateStats(); document.getElementById('state-name').value = state.name; paintFlag(); updateUndoBtn(); }

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
function importFile(file) { const r = new FileReader(); r.onload = () => { try { state = migrate(Object.assign(freshState(), JSON.parse(r.result))); undoStack = []; save(); deselect(); document.getElementById('state-name').value = state.name; buildPalette(); renderAll(); locate(); flash('Государство загружено'); } catch (e) { flash('Не удалось прочитать файл', true); } }; r.readAsText(file); }
let flashTimer = null;
function flash(msg, bad) { const t = document.getElementById('toast'); t.textContent = msg; t.style.color = bad ? '#E0245E' : ''; t.classList.remove('hidden'); clearTimeout(flashTimer); flashTimer = setTimeout(() => t.classList.add('hidden'), 1800); }

/* ════════════════ TRAFFIC SIM (cars + people) ════════════════ */
const CAR_COLORS = ['#e74c3c', '#3498db', '#ecf0f1', '#2c3e50', '#f1c40f', '#16a085', '#e67e22', '#8e44ad', '#bdc3c7'];
const PED_COLORS = ['#ffd24a', '#5ad06a', '#ff8a5c', '#5cc8ff', '#e8e8e8', '#d98cff'];
const sim = { on: false, cars: [], peds: [], driveLines: [], pedLines: [], raf: 0, last: 0, t: 0, selected: null, follow: false, _panelT: 0 };
let simCanvas = null, simCtx = null;
function resizeSim() { if (!simCanvas) return; const dpr = window.devicePixelRatio || 1; simCanvas.width = innerWidth * dpr; simCanvas.height = innerHeight * dpr; simCanvas.style.width = innerWidth + 'px'; simCanvas.style.height = innerHeight + 'px'; }

function roadLen(r) { let d = 0; for (let i = 1; i < r.length; i++) d += distMeters(r[i - 1][0], r[i - 1][1], r[i][0], r[i][1]); return d; }
function makeCar(line) { return { line, seg: randInt(Math.max(1, line.length - 1)), t: Math.random(), fwd: Math.random() < .5, spd: 8 + Math.random() * 6, v: 0, color: CAR_COLORS[randInt(CAR_COLORS.length)] }; }
const NAME_M = ['Иван', 'Пётр', 'Алексей', 'Дмитрий', 'Сергей', 'Андрей', 'Николай', 'Михаил', 'Олег', 'Артём', 'Максим', 'Роман', 'Егор', 'Кирилл', 'Фёдор', 'Павел', 'Денис', 'Глеб'];
const NAME_F = ['Анна', 'Мария', 'Елена', 'Ольга', 'Татьяна', 'Ирина', 'Наталья', 'Светлана', 'Юлия', 'Дарья', 'Екатерина', 'Софья', 'Полина', 'Вера', 'Алиса', 'Ксения', 'Нина'];
const SURNAME = ['Иванов', 'Петров', 'Смирнов', 'Кузнецов', 'Соколов', 'Попов', 'Лебедев', 'Козлов', 'Новиков', 'Морозов', 'Волков', 'Орлов', 'Зайцев', 'Фролов', 'Гусев', 'Беляев'];
const JOBS = ['рабочий', 'учитель', 'врач', 'продавец', 'инженер', 'студент', 'пенсионер', 'водитель', 'повар', 'программист', 'строитель', 'бухгалтер', 'музыкант', 'садовник', 'почтальон'];
let _cid = 0;
function makeCitizen(line) {
  const female = Math.random() < 0.5;
  const first = female ? NAME_F[randInt(NAME_F.length)] : NAME_M[randInt(NAME_M.length)];
  const last = SURNAME[randInt(SURNAME.length)] + (female ? 'а' : '');
  return {
    id: ++_cid, name: first + ' ' + last, female, age: 16 + randInt(64), job: JOBS[randInt(JOBS.length)],
    line, seg: randInt(Math.max(1, line.length - 1)), t: Math.random(), fwd: Math.random() < .5,
    spd: 1.0 + Math.random() * 0.7, color: PED_COLORS[randInt(PED_COLORS.length)],
    dest: null, goal: null, status: 'идёт', idle: 0
  };
}
function buildSim() {
  sim.cars = []; sim.peds = [];
  sim.driveLines = state.roads.concat(state.alleys);          // машины ездят по дорогам И переулкам
  sim.driveLines.forEach(r => { if (r.length < 2) return; const n = Math.max(1, Math.round(roadLen(r) / 45)); for (let k = 0; k < n; k++) sim.cars.push(makeCar(r)); });
  sim.pedLines = [];                                           // связная пешеходная сеть: тропинки + переулки + тротуары
  state.paths.forEach(p => { if (p.length >= 2 && roadLen(p) > 4) sim.pedLines.push(p); });
  state.alleys.forEach(a => { if (a.length >= 2 && roadLen(a) > 4) sim.pedLines.push(a); });   // пешеходы ходят и по переулкам (узкие, общие с машинами)
  state.roads.forEach(r => {
    const walk = state.roadWalk[roadKey(r)] || 'both';
    const sides = walk === 'both' ? [SIDEWALK_OFF, -SIDEWALK_OFF] : walk === 'left' ? [SIDEWALK_OFF] : walk === 'right' ? [-SIDEWALK_OFF] : [];
    sides.forEach(o => { const sw = offsetLine(r, o); if (sw.length >= 2 && roadLen(sw) > 10) sim.pedLines.push(sw); });
  });
  sim.pedLines.forEach(line => { const n = Math.max(1, Math.round(roadLen(line) / 40)); for (let k = 0; k < n; k++) sim.peds.push(makeCitizen(line)); });
  if (sim.cars.length > 800) sim.cars.length = 800;
  if (sim.peds.length > 500) sim.peds.length = 500;
  sim.selected = null; sim.follow = false;
  sim.peds.forEach(assignDest);                                // у каждого жителя — цель (куда направляется)
}
function pedNearestPoint(ll) {                                 // ближайшая точка пешеходной сети к latlng
  let best = null, bd = Infinity;
  for (const line of sim.pedLines) for (let i = 1; i < line.length; i++) {
    const pr = projOnSegLL([ll[0], ll[1]], line[i - 1], line[i]), d = distMeters(ll[0], ll[1], pr[0], pr[1]);
    if (d < bd) { bd = d; best = { line, seg: i - 1, pos: pr }; }
  }
  return best;
}
function assignDest(cit) {                                     // выбрать здание-цель и точку на сети рядом с ним
  const builds = state.buildings.filter(b => b.type !== 'tree' && isFinite(b.lat) && isFinite(b.lng));
  if (!builds.length || !sim.pedLines.length) { cit.dest = null; cit.goal = null; cit.status = 'гуляет'; return; }
  const b = builds[randInt(builds.length)], np = pedNearestPoint([b.lat, b.lng]);
  const g = np ? np.pos : [b.lat, b.lng];
  if (!isFinite(g[0]) || !isFinite(g[1])) { cit.dest = null; cit.goal = null; cit.status = 'гуляет'; return; }   // защита от битых координат
  cit.dest = b; cit.goal = g;
  cit.status = 'идёт ' + (b.type === 'shop' ? 'в магазин' : 'к дому');
  orientToGoal(cit);                                          // сразу повернуть В СТОРОНУ цели (а не куда смотрел)
}
function orientToGoal(cit) {                                   // выбрать направление по текущей линии, что ближе к цели
  if (!cit.goal || !cit.line || !cit.line[cit.seg + 1]) return;
  const cur = lerpPos(cit.line, cit.seg, cit.t), ah = lerpPos(cit.line, cit.seg, Math.min(1, cit.t + 0.12));
  cit.fwd = distMeters(ah[0], ah[1], cit.goal[0], cit.goal[1]) <= distMeters(cur[0], cur[1], cit.goal[0], cit.goal[1]);
}
function lerpPos(line, seg, t) { const a = line[seg], b = line[seg + 1]; t = Math.max(0, Math.min(1, t)); return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]; }
function segBear(line, seg, fwd) { const a = line[seg], b = line[seg + 1]; let ang = Math.atan2((b[0] - a[0]) * MPD_LAT, (b[1] - a[1]) * mPerDegLng(a[0])); return fwd ? ang : ang + Math.PI; }
function carBlocked(c) {
  if (!state.lights.length) return false;
  const r = c.line; if (!r || !r[c.seg + 1]) return false;
  const p = lerpPos(r, c.seg, c.t), dir = segBear(r, c.seg, c.fwd), ux = Math.cos(dir), uy = Math.sin(dir);
  const near = LINE_M.road * 1.15, far = LINE_M.road * 2.4;       // стоп-линия за зеброй … зона начала торможения
  for (const l of state.lights) {
    const dE = (l.lng - p[1]) * mPerDegLng(p[0]), dN = (l.lat - p[0]) * MPD_LAT;
    const proj = dE * ux + dN * uy;              // светофор впереди по ходу (м)
    const lat = Math.abs(-dE * uy + dN * ux);    // боковое смещение — светофор должен быть на ЭТОЙ дороге
    if (proj > near && proj < far && lat < LINE_M.road) {         // перед зеброй и ещё НЕ въехал — стоп на красный; въехавшую (proj<=near) не держим → не застрянет на перекрёстке
      const a = ((dir * 180 / Math.PI) % 180 + 180) % 180, ns = a > 45 && a < 135;
      if (ns !== phaseGreenNS()) return true;
    }
  }
  return false;
}
function netJunction(ag, lines, atEnd, tol) {     // войти на ЛЮБУЮ линию рядом с концом — в т.ч. в середину сегмента (повороты на T-перекрёстках)
  const line = ag.line, v = atEnd ? line[line.length - 1] : line[0], opts = [];
  for (const l2 of lines) { if (l2 === line || l2.length < 2) continue;
    for (let i = 1; i < l2.length; i++) {
      const a = l2[i - 1], b = l2[i], E = (b[1] - a[1]) * mPerDegLng(a[0]), N = (b[0] - a[0]) * MPD_LAT, L2 = E * E + N * N;
      const vE = (v[1] - a[1]) * mPerDegLng(a[0]), vN = (v[0] - a[0]) * MPD_LAT;
      let t = L2 ? (vE * E + vN * N) / L2 : 0; t = Math.max(0, Math.min(1, t));
      if (Math.hypot(vE - t * E, vN - t * N) < tol) { opts.push([l2, i - 1, t]); break; }
    }
  }
  if (!opts.length) { ag.fwd = !ag.fwd; ag.t = atEnd ? 0.985 : 0.015; return; }   // тупик — разворот
  const [nl, seg, t] = opts[randInt(opts.length)];
  ag.line = nl; ag.seg = seg; ag.t = Math.max(0.04, Math.min(0.96, t)); ag.fwd = Math.random() < 0.5;
}
function junction(c, atEnd) { netJunction(c, sim.driveLines, atEnd, 6); }
function stepCar(c, dt) {
  const r = c.line; if (!r || r.length < 2 || !r[c.seg] || !r[c.seg + 1]) { if (!sim.driveLines.length) { c.dead = true; return; } Object.assign(c, makeCar(sim.driveLines[randInt(sim.driveLines.length)])); return; }
  const a = r[c.seg], b = r[c.seg + 1], len = distMeters(a[0], a[1], b[0], b[1]) || 1;
  c.t += (c.fwd ? 1 : -1) * (c.v || 0) * dt / len;
  if (c.t > 1) { if (c.seg < r.length - 2) { c.seg++; c.t = 0; } else junction(c, true); }
  else if (c.t < 0) { if (c.seg > 0) { c.seg--; c.t = 1; } else junction(c, false); }
}
const phaseGreenNS = () => Math.floor(sim.t / 5) % 2 === 0;   // фаза: зелёный С-Ю / В-З по 5 с
function roadCum(r) { const c = [0]; for (let i = 1; i < r.length; i++) c.push(c[i - 1] + distMeters(r[i - 1][0], r[i - 1][1], r[i][0], r[i][1])); return c; }
function computeCarSpeeds(dt) {                 // car-following: подстройка скорости под переднюю + красный
  const groups = new Map();
  for (const c of sim.cars) { const r = c.line; if (!r || r.length < 2) { c.v = 0; continue; } if (!groups.has(r)) groups.set(r, []); groups.get(r).push(c); }
  for (const [r, list] of groups) { const cum = roadCum(r), total = cum[cum.length - 1]; for (const c of list) { const sl = (cum[c.seg + 1] - cum[c.seg]) || 1, along = cum[c.seg] + c.t * sl; c._tr = c.fwd ? along : (total - along); } }
  for (const c of sim.cars) {
    const r = c.line; if (!r || r.length < 2) { c.v = 0; continue; }
    let gap = Infinity;
    for (const o of groups.get(r)) { if (o === c || o.fwd !== c.fwd) continue; const d = o._tr - c._tr; if (d > 0 && d < gap) gap = d; }
    gap -= 5.2;                                 // длина машины
    let target = c.spd;
    if (gap < 13) target = Math.min(target, Math.max(0, (gap - 2.4) * 1.3));   // тормозим за передней
    if (carBlocked(c)) target = 0;
    const v = c.v || 0;
    c.v = target > v ? Math.min(target, v + 9 * dt) : Math.max(target, v - 28 * dt);   // плавный разгон/торможение
    if (c.v < 0) c.v = 0;
  }
}
function citizenJunction(p, atEnd) {              // на стыке свернуть В СТОРОНУ ЦЕЛИ (жадно), иначе — случайно
  if (!p.goal) { netJunction(p, sim.pedLines, atEnd, 6); return; }
  const line = p.line, v = atEnd ? line[line.length - 1] : line[0], opts = [];
  for (const l2 of sim.pedLines) { if (l2 === line || l2.length < 2) continue;
    for (let i = 1; i < l2.length; i++) {
      const a = l2[i - 1], b = l2[i], E = (b[1] - a[1]) * mPerDegLng(a[0]), N = (b[0] - a[0]) * MPD_LAT, L2 = E * E + N * N;
      const vE = (v[1] - a[1]) * mPerDegLng(a[0]), vN = (v[0] - a[0]) * MPD_LAT;
      let t = L2 ? (vE * E + vN * N) / L2 : 0; t = Math.max(0, Math.min(1, t));
      if (Math.hypot(vE - t * E, vN - t * N) < 6) { opts.push([l2, i - 1, t]); break; }
    }
  }
  if (!opts.length) { p.fwd = !p.fwd; p.t = atEnd ? 0.985 : 0.015; return; }   // тупик — разворот
  let best = null, bestD = Infinity;
  for (const [nl, seg, t] of opts) for (const fwd of [true, false]) {
    const pos = lerpPos(nl, seg, fwd ? Math.min(1, t + 0.12) : Math.max(0, t - 0.12));
    const d = distMeters(pos[0], pos[1], p.goal[0], p.goal[1]);
    if (d < bestD) { bestD = d; best = [nl, seg, t, fwd]; }
  }
  if (!best) { const o = opts[randInt(opts.length)]; best = [o[0], o[1], o[2], Math.random() < 0.5]; p.goal = null; }   // цель недостижима/битая → идём случайно, не падаем
  p.line = best[0]; p.seg = best[1]; p.t = Math.max(0.04, Math.min(0.96, best[2])); p.fwd = best[3];
}
function stepPed(p, dt) {
  if (p.idle > 0) { p.idle -= dt; if (p.idle <= 0) assignDest(p); return; }   // стоит у цели, потом новая цель
  const line = p.line; if (!line || line.length < 2 || !line[p.seg] || !line[p.seg + 1]) { p.dead = true; return; }
  const a = line[p.seg], b = line[p.seg + 1], len = distMeters(a[0], a[1], b[0], b[1]) || 1;
  p.t += (p.fwd ? 1 : -1) * p.spd * dt / len;
  if (p.t > 1) { if (p.seg < line.length - 2) { p.seg++; p.t = 0; } else citizenJunction(p, true); }
  else if (p.t < 0) { if (p.seg > 0) { p.seg--; p.t = 1; } else citizenJunction(p, false); }
  if (p.goal && p.line && p.line[p.seg + 1]) {                  // пришёл к цели?
    const pos = lerpPos(p.line, p.seg, p.t);
    if (distMeters(pos[0], pos[1], p.goal[0], p.goal[1]) < 7) { p.idle = 2 + Math.random() * 5; p.status = 'на месте: ' + (p.dest && p.dest.type === 'shop' ? 'магазин' : 'дом'); p.goal = null; }
  }
}
function pickCitizen(cp) {                          // ближайший житель к точке экрана (для клика)
  let best = null, bd = 16;
  for (const p of sim.peds) { if (p.dead) continue; const line = p.line; if (!line || !line[p.seg + 1]) continue;
    const pos = lerpPos(line, p.seg, p.t), q = map.latLngToContainerPoint([pos[0], pos[1]]), d = Math.hypot(q.x - cp.x, q.y - cp.y);
    if (d < bd) { bd = d; best = p; }
  }
  return best;
}
function selectCitizen(c) { sim.selected = c; sim.follow = true; document.getElementById('citizen').classList.remove('hidden'); updateCitizenPanel(); }
function deselectCitizen() { sim.selected = null; sim.follow = false; const p = document.getElementById('citizen'); if (p) p.classList.add('hidden'); }
function updateCitizenPanel() {
  const c = sim.selected; if (!c) return;
  document.getElementById('cz-name').textContent = c.name;
  const dest = c.dest ? (c.dest.type === 'shop' ? 'магазин' : 'дом') : 'нет';
  document.getElementById('cz-body').innerHTML =
    `<div class="cz-row"><span>${c.female ? 'Женщина' : 'Мужчина'}, ${c.age}</span><span>${c.job}</span></div>` +
    `<div class="cz-row"><span>Статус</span><b>${c.status || 'идёт'}</b></div>` +
    `<div class="cz-row"><span>Направляется</span><b>${dest}</b></div>`;
}
function roundRect(ctx, x, y, w, h, r) { ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath(); }
function drawLightSignals(ctx, dpr, W, H) {       // цветной свет от светофора на каждую дорогу
  if (!state.lights.length) return;
  const greenNS = phaseGreenNS();
  for (const l of state.lights) for (const ang of roadsAt(l.lat, l.lng, LINE_M.road * 1.4)) {
    const a = ((ang * 180 / Math.PI) % 180 + 180) % 180, isns = a > 45 && a < 135, col = (isns === greenNS) ? '70,208,106' : '255,82,71';
    for (const s of [1, -1]) {
      const pll = offset(l.lat, l.lng, Math.cos(ang) * 9 * s, Math.sin(ang) * 9 * s);
      if (!roadsAt(pll[0], pll[1], LINE_M.road * 0.7).some(d => { const df = Math.abs((((d - ang) * 180 / Math.PI) % 180 + 180) % 180); return Math.min(df, 180 - df) < 25; })) continue;   // светим только туда, где дорога ПРОДОЛЖАЕТСЯ (далеко от центра, чтобы не цеплять встречную сторону)
      const cp = map.latLngToContainerPoint([pll[0], pll[1]]); if (cp.x < -40 || cp.y < -40 || cp.x > W + 40 || cp.y > H + 40) continue;
      const rad = Math.max(7, mToPx(5.5)) * dpr, x = cp.x * dpr, y = cp.y * dpr, g = ctx.createRadialGradient(x, y, 0, x, y, rad);
      g.addColorStop(0, `rgba(${col},0.6)`); g.addColorStop(1, `rgba(${col},0)`);
      ctx.fillStyle = g; ctx.beginPath(); ctx.arc(x, y, rad, 0, 6.2832); ctx.fill();
    }
  }
}
function drawSim() {
  const ctx = simCtx, dpr = window.devicePixelRatio || 1;
  ctx.clearRect(0, 0, simCanvas.width, simCanvas.height);
  const W = innerWidth, H = innerHeight;
  drawLightSignals(ctx, dpr, W, H);
  const cl = Math.max(1.2, mToPx(3.8)), cw = Math.max(0.6, mToPx(1.7));   // машина мельче (3.8×1.7 м) + низкий пол — сильнее ужимается при отдалении (не «грузовой корабль»)
  for (const c of sim.cars) {
    const r = c.line; if (!r || !r[c.seg + 1] || c.dead) continue;
    const ang = segBear(r, c.seg, c.fwd), pos = lerpPos(r, c.seg, c.t);
    const ll = pos;   // движение по ЦЕНТРУ дороги/переулка (без правой полосы)
    const cp = map.latLngToContainerPoint([ll[0], ll[1]]); if (cp.x < -30 || cp.y < -30 || cp.x > W + 30 || cp.y > H + 30) continue;
    ctx.save(); ctx.translate(cp.x * dpr, cp.y * dpr); ctx.rotate(-ang);
    ctx.fillStyle = c.color; roundRect(ctx, -cl / 2 * dpr, -cw / 2 * dpr, cl * dpr, cw * dpr, Math.min(cw / 2, 3) * dpr); ctx.fill();
    ctx.fillStyle = 'rgba(20,24,30,.6)'; ctx.fillRect(cl * 0.12 * dpr, -cw / 2 * dpr, cl * 0.22 * dpr, cw * dpr);
    ctx.restore();
  }
  const bodyR = Math.max(1, mToPx(0.55)), headR = Math.max(0.6, bodyR * 0.55);   // пешеход: плечи + голова (мельче)
  const sel = sim.selected;
  if (sel && !sel.dead && sel.line && sel.line[sel.seg + 1] && sel.goal) {        // пунктир выбранного жителя к его цели
    const sp = lerpPos(sel.line, sel.seg, sel.t), a = map.latLngToContainerPoint([sp[0], sp[1]]), b = map.latLngToContainerPoint([sel.goal[0], sel.goal[1]]);
    ctx.strokeStyle = 'rgba(217,119,87,.55)'; ctx.lineWidth = 2 * dpr; ctx.setLineDash([6 * dpr, 6 * dpr]);
    ctx.beginPath(); ctx.moveTo(a.x * dpr, a.y * dpr); ctx.lineTo(b.x * dpr, b.y * dpr); ctx.stroke(); ctx.setLineDash([]);
  }
  for (const p of sim.peds) {
    if (p.dead) continue; const line = p.line; if (!line || !line[p.seg + 1]) continue;
    const pos = lerpPos(line, p.seg, p.t), cp = map.latLngToContainerPoint([pos[0], pos[1]]); if (cp.x < -10 || cp.y < -10 || cp.x > W + 10 || cp.y > H + 10) continue;
    const x = cp.x * dpr, y = cp.y * dpr, isSel = p === sel, br = isSel ? bodyR * 1.5 : bodyR, hr = isSel ? headR * 1.5 : headR;
    if (isSel) { ctx.strokeStyle = '#D97757'; ctx.lineWidth = 2.2 * dpr; ctx.beginPath(); ctx.arc(x, y, (br + 4) * dpr, 0, 6.2832); ctx.stroke(); }
    ctx.fillStyle = p.color; ctx.beginPath(); ctx.arc(x, y, br * dpr, 0, 6.2832); ctx.fill();
    ctx.fillStyle = 'rgba(25,25,28,.9)'; ctx.beginPath(); ctx.arc(x, y, hr * dpr, 0, 6.2832); ctx.fill();
  }
}
function simLoop(ts) {
  if (!sim.on) return;
  if (!sim.last) sim.last = ts; let dt = (ts - sim.last) / 1000; sim.last = ts; if (dt > 0.1) dt = 0.1;
  sim.t += dt;
  try {
    computeCarSpeeds(dt);
    for (const c of sim.cars) stepCar(c, dt);
    for (const p of sim.peds) stepPed(p, dt);
    if (sim.cars.some(c => c.dead)) sim.cars = sim.cars.filter(c => !c.dead);
    if (sim.peds.some(p => p.dead)) sim.peds = sim.peds.filter(p => !p.dead);
    if (sim.selected) {
      if (sim.selected.dead || !sim.peds.includes(sim.selected)) deselectCitizen();
      else {
        const s = sim.selected, line = s.line;
        if (sim.follow && line && line[s.seg + 1]) {               // камера следует за жителем
          const pos = lerpPos(line, s.seg, s.t), cp = map.latLngToContainerPoint([pos[0], pos[1]]), cen = map.getSize().divideBy(2);
          if (Math.abs(cp.x - cen.x) > 2 || Math.abs(cp.y - cen.y) > 2) map.panTo([pos[0], pos[1]], { animate: false });
        }
        if (sim.t - sim._panelT > 0.3) { sim._panelT = sim.t; updateCitizenPanel(); }   // живой статус
      }
    }
    drawSim();
  } catch (e) { if (!sim._warned) { console.warn('sim frame error:', e); sim._warned = true; } }   // один битый кадр НЕ убивает весь сим
  sim.raf = requestAnimationFrame(simLoop);
}
function startSim() {
  if (!state.roads.length) { flash('Сначала проложи дороги', true); return; }
  resizeSim(); buildSim(); sim.on = true; sim.last = 0;
  document.querySelector('[data-action="sim"]').classList.add('active');
  sim.raf = requestAnimationFrame(simLoop);
  flash(`Движение: ${sim.cars.length} машин, ${sim.peds.length} пешеходов`);
}
function stopSim() { sim.on = false; deselectCitizen(); if (sim.raf) cancelAnimationFrame(sim.raf); if (simCtx) simCtx.clearRect(0, 0, simCanvas.width, simCanvas.height); const b = document.querySelector('[data-action="sim"]'); if (b) b.classList.remove('active'); }
function toggleSim() { sim.on ? stopSim() : startSim(); }

/* ════════════════ WIRING ════════════════ */
function wire() {
  document.querySelectorAll('.tool[data-tool]').forEach(b => { const t = b.dataset.tool; b.innerHTML = ICONS[t === 'erase' ? 'trash' : t] || ''; b.onclick = () => setTool(t); });
  const map_ = { undo: ICONS.undo, save: ICONS.download, load: ICONS.upload };
  document.querySelector('[data-action="undo"]').innerHTML = map_.undo || ''; document.querySelector('[data-action="undo"]').onclick = undo;
  document.querySelector('[data-action="save"]').innerHTML = map_.save || ''; document.querySelector('[data-action="save"]').onclick = exportFile;
  document.querySelector('[data-action="load"]').innerHTML = map_.load || ''; document.querySelector('[data-action="load"]').onclick = () => document.getElementById('import-file').click();
  document.querySelector('[data-action="sim"]').innerHTML = ICONS.car || ''; document.querySelector('[data-action="sim"]').onclick = toggleSim;
  document.getElementById('import-file').onchange = e => { if (e.target.files[0]) importFile(e.target.files[0]); e.target.value = ''; };
  document.getElementById('locate').innerHTML = ICONS.target || ''; document.getElementById('locate').onclick = locate;
  document.getElementById('draw-undo').onclick = undoVertex;
  document.getElementById('draw-done').onclick = finishDraw;
  document.getElementById('draw-cancel').onclick = () => { cancelDraw(); setToolIdle(); };
  document.getElementById('border-done').onclick = () => { exitBorderEdit(); setToolIdle(); };
  document.getElementById('border-redraw').onclick = () => { pushUndo(); exitBorderEdit(); state.border = null; renderTerritory(); updateStats(); startDraw('borders'); };
  document.getElementById('edit-del').onclick = () => { if (selected) removeBuilding(selected); };
  document.getElementById('edit-done').onclick = deselect;
  document.getElementById('edit-collapse').onclick = () => document.getElementById('edit').classList.toggle('collapsed');
  document.getElementById('cz-close').onclick = deselectCitizen;
  document.getElementById('gen-side').onclick = () => { genSel.side = genSel.side === 'both' ? 'left' : genSel.side === 'left' ? 'right' : 'both'; updateGenSideBtn(); drawGenSegs(); };
  document.getElementById('gen-ok').onclick = confirmGen;
  document.getElementById('gen-cancel').onclick = endGenSelect;
  document.getElementById('tb-collapse').onclick = () => document.getElementById('toolbar').classList.toggle('collapsed');
  document.querySelectorAll('[data-zone]').forEach(b => b.onclick = () => { genSel.zone = b.dataset.zone; document.querySelectorAll('[data-zone]').forEach(x => x.classList.toggle('active', x === b)); });
  document.querySelectorAll('[data-walk]').forEach(b => b.onclick = () => { if (walkBarKey) { state.roadWalk[walkBarKey] = b.dataset.walk; save(); renderRoads(); renderAlleys(); } document.querySelectorAll('[data-walk]').forEach(x => x.classList.toggle('active', x === b)); closeWalkBar(); });
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
    else if (e.key === 'Escape') { closeCtxMenu(); closeWalkBar(); if (genSel.active) endGenSelect(); else if (draw.active) { cancelDraw(); setToolIdle(); } else if (borderEdit.active) { exitBorderEdit(); setToolIdle(); } else if (selected) deselect(); else document.getElementById('palette').classList.add('hidden'); }
    else if (e.key === 'Backspace' && draw.active) { e.preventDefault(); undoVertex(); }
  });
}

/* ════════════════ BOOT ════════════════ */
/* ════════════════ МУЛЬТИПЛЕЕР (общий мир, аккаунты GhostEcos) ════════════════ */
const MP_API = '/api/nation', MP_STORE = 'ghostnation:mp';
const mp = { mode: localStorage.getItem('ghostnation:mode') === 'mp' ? 'mp' : 'local', country: null, balance: 0, pop: 0, worldLayer: null, saveTimer: null };
function isMP() { return mp.mode === 'mp'; }

// SSO-токен GhostEcos (общий для всей экосистемы — НЕ ТРОГАТЬ его в игре)
function ssoToken() { return localStorage.getItem('gs_token'); }
// JWT игры (живёт 24ч, перевыпускается из gs_token)
function gnJwt() { return localStorage.getItem('gn_jwt'); }
function gnJwtExp() { return parseInt(localStorage.getItem('gn_jwt_exp') || '0', 10); }
function gnJwtFresh() {
  const exp = gnJwtExp();
  return gnJwt() && exp && (Date.now() / 1000) < (exp - 60);  // запас 60с
}

// Получить или перевыпустить JWT через SSO
async function refreshGnJwt() {
  const sso = ssoToken();
  if (!sso) return null;
  try {
    const r = await fetch('/api/soc/sso/jwt', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + sso },
    });
    if (!r.ok) {
      if (r.status === 401) {
        // gs_token недействителен (юзер разлогинился в GS / истёк).
        // НЕ удаляем чужой gs_token — пусть GS сам разберётся.
        return null;
      }
      throw new Error('sso/jwt: HTTP ' + r.status);
    }
    const d = await r.json();
    localStorage.setItem('gn_jwt', d.jwt);
    localStorage.setItem('gn_jwt_exp', String(d.expires_at));
    return d.jwt;
  } catch (e) { console.warn('[gn_jwt]', e); return null; }
}

// JWT для запросов в /api/nation (с автоперевыпуском)
async function mpToken() {
  if (gnJwtFresh()) return gnJwt();
  return await refreshGnJwt();
}

async function mpApi(path, opts) {
  opts = opts || {};
  const h = { 'Content-Type': 'application/json' };
  const t = await mpToken();
  if (t) h['Authorization'] = 'Bearer ' + t;
  return fetch(MP_API + path, Object.assign({}, opts, { headers: Object.assign(h, opts.headers || {}) }));
}
function mpInit() {
  if (!document.getElementById('mode-local')) return;   // UI мультиплеера ещё не добавлен → MP спит, играем локально
  mp.worldLayer = L.layerGroup().addTo(map);
  document.getElementById('mode-local').onclick = () => setMode('local');
  document.getElementById('mode-mp').onclick = () => setMode('mp');
  document.getElementById('mp-login-go').onclick = mpSubmitLogin;
  document.getElementById('mp-login-cancel').onclick = () => { hideMpLogin(); if (isMP()) setMode('local'); };
  const regBtn = document.getElementById('mp-login-register');
  if (regBtn) regBtn.onclick = mpGoRegister;
  document.getElementById('mp-logout').onclick = mpLogout;
  updateModeUI();
  if (isMP()) enterMP();
}
function setMode(m) {
  if (m === mp.mode) return;
  if (mp.mode === 'local') localStorage.setItem(STORE_KEY, JSON.stringify(state));
  mp.mode = m; localStorage.setItem('ghostnation:mode', m); updateModeUI();
  if (m === 'local') { mp.worldLayer.clearLayers(); mp.country = null; state = load(); document.getElementById('state-name').value = state.name; renderAll(); flash('Локальный режим'); }
  else enterMP();
}
function updateModeUI() {
  document.getElementById('mode-local').classList.toggle('active', !isMP());
  document.getElementById('mode-mp').classList.toggle('active', isMP());
  document.getElementById('mp-bar').classList.toggle('hidden', !isMP());
  if (isMP()) updateBalanceUI();
}
function updateBalanceUI() {
  const b = document.getElementById('mp-balance'); if (b) b.textContent = Math.round(mp.balance) + ' gost';
  const p = document.getElementById('mp-pop'); if (p) p.textContent = mp.pop + ' чел';
  const lo = document.getElementById('mp-logout'); if (lo) lo.classList.toggle('hidden', !ssoToken());
}
function enterMP() { if (!ssoToken()) { showMpLogin(); return; } mpLoadMine().then(mpLoadWorld); }
async function mpLoadMine() {
  try {
    const r = await mpApi('/mine');
    if (r.status === 401) {
      // gn_jwt истёк или невалиден. Сначала попробуем перевыпустить через SSO.
      localStorage.removeItem('gn_jwt'); localStorage.removeItem('gn_jwt_exp');
      const fresh = await refreshGnJwt();
      if (fresh) return mpLoadMine();  // retry один раз
      // Если SSO тоже мёртв — НЕ удаляем gs_token (это общий токен экосистемы),
      // просто показываем экран входа через GhostEcos.
      showMpLogin(); return;
    }
    const d = await r.json();
    if (d.country) {
      const c = d.country; mp.country = c; mp.balance = c.balance || 0; mp.pop = c.population || 0;
      state = migrate(Object.assign(freshState(), c.state || {})); state.name = c.name || ''; state.color = c.color || state.color; state.border = c.border || null;
      document.getElementById('state-name').value = state.name; renderAll(); updateBalanceUI();
      if (state.border && state.border.length) try { map.fitBounds(L.latLngBounds(state.border).pad(0.25)); } catch (e) {}
      flash('Загружена твоя страна');
    } else { mp.country = null; mp.balance = 1500; mp.pop = 0; state = freshState(); renderAll(); updateBalanceUI(); flash('Нарисуй границу — застолби свою территорию', true); }
  } catch (e) { flash('Сервер недоступен', true); }
}
function mpSyncSave() {
  if (!isMP() || !ssoToken() || !mp.country) return;
  clearTimeout(mp.saveTimer);
  mp.saveTimer = setTimeout(async () => {
    try { const r = await mpApi('/mine', { method: 'PUT', body: JSON.stringify({ state }) });
      if (r.ok) { const d = await r.json(); mp.balance = d.balance; mp.pop = d.population != null ? d.population : mp.pop; updateBalanceUI(); }
      else if (r.status === 402) { const d = await r.json().catch(() => ({})); flash(d.detail || 'Не хватает gost', true); }
    } catch (e) {}
  }, 900);
}
async function mpClaim() {
  if (!isMP() || !ssoToken() || !state.border || state.border.length < 3) return;
  // Защита от двойного claim (быстрый повторный finishDraw)
  if (mp._claiming) return;
  mp._claiming = true;
  try {
    const r = await mpApi('/claim', { method: 'POST', body: JSON.stringify({ name: state.name || 'Моя страна', color: state.color, border: state.border }) });
    const d = await r.json().catch(() => ({}));
    if (r.ok) { mp.balance = d.balance; mp.country = mp.country || {}; updateBalanceUI(); flash('Территория застолблена' + (d.cost ? ' · −' + Math.round(d.cost) + ' gost' : '')); mpLoadWorld(); mpSyncSave(); }
    else { flash(d.detail || 'Не удалось застолбить', true); }
  } catch (e) { flash('Сервер недоступен', true); }
  finally { mp._claiming = false; }
}
async function mpLoadWorld() {
  if (!isMP() || !map || !mp.worldLayer) return;
  const b = map.getBounds();
  try { const r = await mpApi(`/world?minlat=${b.getSouth()}&minlng=${b.getWest()}&maxlat=${b.getNorth()}&maxlng=${b.getEast()}`); const d = await r.json(); mpRenderWorld(d.countries || []); } catch (e) {}
}
function mpRenderWorld(countries) {
  mp.worldLayer.clearLayers();
  const mine = mp.country && mp.country.owner;
  for (const c of countries) {
    if (c.owner === mine || !c.border || c.border.length < 3) continue;
    L.polygon(c.border, { pane: 'pane-territory', color: c.color || '#888', weight: 2, opacity: .6, fillColor: c.color || '#888', fillOpacity: .07, interactive: false, dashArray: '5 4' }).addTo(mp.worldLayer);
    if (map.getZoom() <= LABEL_MAX_ZOOM) L.marker(borderCentroid(c.border), { pane: 'markerPane', interactive: false, icon: L.divIcon({ className: 'country-label-wrap', html: `<div class="country-label" style="--c:${c.color || '#888'}">${escLabel(c.name || c.owner)}</div>`, iconSize: [0, 0], iconAnchor: [0, 0] }) }).addTo(mp.worldLayer);
  }
}
function showMpLogin() { if (ssoToken()) return; document.getElementById('mp-login').classList.remove('hidden'); }
function hideMpLogin() { document.getElementById('mp-login').classList.add('hidden'); }

// Вход через GhostEcos: открывает /social/ с ?return=URL, после логина юзер
// возвращается обратно в игру с уже выставленным gs_token в localStorage.
async function mpSubmitLogin() {
  // Если в форме оставили пароль — пробуем войти через GhostSocial напрямую.
  // Иначе — редирект на /social/ (там и регистрация, и вход).
  const u = (document.getElementById('mp-user') || {}).value;
  const p = (document.getElementById('mp-pass') || {}).value;
  if (u && p) {
    try {
      const r = await fetch('/api/soc/login', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: u.trim().toLowerCase(), password: p }),
      });
      const d = await r.json().catch(() => ({}));
      if (r.ok && d.token) {
        localStorage.setItem('gs_token', d.token);
        await refreshGnJwt();
        hideMpLogin(); flash('Вход выполнен'); enterMP(); return;
      }
      flash(d.detail || 'Неверный логин или пароль', true); return;
    } catch (e) { flash('Сервер недоступен', true); return; }
  }
  // Без логина/пароля — редирект на GhostSocial для входа/регистрации
  location.href = '/social/?return=' + encodeURIComponent(location.pathname);
}

// Регистрация — тоже через GhostSocial (один аккаунт на всю экосистему)
function mpGoRegister() {
  location.href = '/social/?action=register&return=' + encodeURIComponent(location.pathname);
}

function mpLogout() {
  // НЕ удаляем gs_token (это общий токен GhostEcos — выход делается из GS).
  // Удаляем только JWT игры и переходим в локальный режим.
  localStorage.removeItem('gn_jwt');
  localStorage.removeItem('gn_jwt_exp');
  mp.country = null; setMode('local');
  flash('Вышел из мультиплеера (общий аккаунт сохранён)');
}

(async function boot() {
  if (typeof L === 'undefined') { document.body.insertAdjacentHTML('beforeend', '<div style="position:fixed;inset:0;display:grid;place-items:center;background:#000;color:#fff;font:16px sans-serif;text-align:center;padding:24px">Не удалось загрузить Leaflet с CDN.<br>Проверь интернет/туннель и обнови страницу.</div>'); return; }
  await loadIcons();
  initMap();
  districtLayer = L.layerGroup().addTo(map);
  roadLayer = L.layerGroup().addTo(map);
  alleyLayer = L.layerGroup().addTo(map);
  pathLayer = L.layerGroup().addTo(map);
  railLayer = L.layerGroup().addTo(map);
  crossLayer = L.layerGroup().addTo(map);
  zebraLayer = L.layerGroup().addTo(map);
  buildLayer = L.layerGroup().addTo(map);
  lightLayer = L.layerGroup().addTo(map);
  countryLabelLayer = L.layerGroup().addTo(map);
  editLayer = L.layerGroup().addTo(map);
  buildPalette(); wire(); renderAll(); mpInit();
  simCanvas = document.getElementById('sim'); simCtx = simCanvas.getContext('2d'); resizeSim();
  window.addEventListener('resize', resizeSim);
})();
