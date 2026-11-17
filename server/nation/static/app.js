/* ════════════════════════════════════════════════════════════
   GhostNation — основай своё государство на спутниковой карте
   Личная песочница. Автосейв localStorage + экспорт/импорт файла.
   ════════════════════════════════════════════════════════════ */

const STORE_KEY = 'ghostnation:v1';
const MP_STORE = 'ghostnation:mp';
const MPD_LAT = 111320;                                   // метров в градусе широты
const mPerDegLng = lat => 111320 * Math.cos(lat * Math.PI / 180);   // метров в градусе долготы
const FLAG_COLORS = ['#D97757', '#E0245E', '#F5A623', '#F8E71C', '#7ED321', '#50E3C2', '#4A90E2', '#9013FE', '#FFFFFF', '#15C26B'];
const DEF = { house: { w: 13, h: 10 }, shop: { w: 13, h: 10 }, tree: { r: 3.5 } };
const ROOF = { house: { fill: '#36b24a', edge: '#0b2c16' }, shop: { fill: '#2E7FE0' } };
const LINE_M = { road: 7, dirt: 5, rail: 3.6, path: 1, alley: 4 };   // ширина на земле, метры
const DIRT_WIDTH_M = LINE_M.dirt;
const SNAP_PX = 14;
const PORCH = '#ffce86';
const PORCH_DEPTH = 1.8, BUILD_GAP = 1.5;        // крыльцо считается частью здания
const SIDEWALK_OFF = LINE_M.road / 2 + 1;        // тротуар вдоль дороги (от центра)

const clampWH = v => Math.min(100, Math.max(1, v));
const clampR  = v => Math.min(50, Math.max(1, v));
const rand    = (a, b) => a + Math.random() * (b - a);
const randInt = n => Math.floor(Math.random() * n);

function freshState() {
  return { name: '', color: FLAG_COLORS[0], border: null, buildings: [], roads: [], rails: [], paths: [], alleys: [], districts: [], lights: [], roadWalk: {}, lineMeta: {}, noZebra: [], crosswalks: [], stations: [], exits: [], parking: [], simulation: { carMode: 'auto', carCount: 0, trainMode: 'auto', trainCount: 0 }, view: { lat: 55.7512, lng: 37.6184, zoom: 12 } };
}
const roadKey = pts => `${pts[0][0].toFixed(5)},${pts[0][1].toFixed(5)}|${pts[pts.length - 1][0].toFixed(5)},${pts[pts.length - 1][1].toFixed(5)}`;
function normalizeLineMeta(meta) { return { surface: meta && meta.surface === 'dirt' ? 'dirt' : 'paved', oneWay: Boolean(meta && meta.oneWay) }; }
function normalizeSimulation(value) {
  const s = value && typeof value === 'object' ? value : {};
  return {
    carMode: s.carMode === 'fixed' ? 'fixed' : 'auto', carCount: Math.max(0, Math.min(800, Math.round(Number(s.carCount) || 0))),
    trainMode: s.trainMode === 'fixed' ? 'fixed' : 'auto', trainCount: Math.max(0, Math.min(80, Math.round(Number(s.trainCount) || 0)))
  };
}
function bindLineMetadata(s) {
  s.lineMeta = s.lineMeta && typeof s.lineMeta === 'object' ? s.lineMeta : {};
  const nextMeta = {}, nextWalk = {}, lines = s.roads.concat(s.alleys);
  for (const line of lines) {
    const key = roadKey(line), meta = normalizeLineMeta(s.lineMeta[key]);
    line._gnMeta = meta; line._gnWalk = s.roadWalk[key] || (s.roads.includes(line) ? 'both' : 'none');
    nextMeta[key] = meta; nextWalk[key] = line._gnWalk;
  }
  s.lineMeta = nextMeta; s.roadWalk = nextWalk;
}
function lineMeta(line) { return normalizeLineMeta(line && (line._gnMeta || state.lineMeta?.[roadKey(line)])); }
function setLineMeta(line, meta) { const value = normalizeLineMeta(meta); line._gnMeta = value; if (state.lineMeta) state.lineMeta[roadKey(line)] = value; return value; }
function lineWalk(line) { return line && (line._gnWalk || state.roadWalk?.[roadKey(line)] || (state.roads.includes(line) ? 'both' : 'none')); }
function setLineWalk(line, walk) { line._gnWalk = walk || 'none'; if (state.roadWalk) state.roadWalk[roadKey(line)] = line._gnWalk; }
function syncLineMetadata() {
  const nextMeta = {}, nextWalk = {};
  for (const line of state.roads.concat(state.alleys)) {
    const key = roadKey(line), meta = lineMeta(line); line._gnMeta = meta; line._gnWalk = lineWalk(line);
    nextMeta[key] = meta; nextWalk[key] = line._gnWalk;
  }
  state.lineMeta = nextMeta; state.roadWalk = nextWalk;
}
function migrate(s) {
  s.roadWalk = s.roadWalk || {}; s.lineMeta = s.lineMeta || {}; s.lights = s.lights || []; s.noZebra = s.noZebra || []; s.crosswalks = s.crosswalks || []; s.districts = s.districts || [];
  s.stations = Array.isArray(s.stations) ? s.stations.filter(x => x && isFinite(x.lat) && isFinite(x.lng)) : [];
  delete s.railSwitches;
  s.exits = Array.isArray(s.exits) ? s.exits.filter(x => x && isFinite(x.lat) && isFinite(x.lng)) : [];
  s.parking = Array.isArray(s.parking) ? s.parking.filter(x => x && isFinite(x.lat) && isFinite(x.lng)) : [];
  s.stations = s.stations.map((x, i) => ({ ...x, name: typeof x.name === 'string' && x.name.trim() ? x.name.trim() : `Station ${i + 1}`, railKey: typeof x.railKey === 'string' ? x.railKey : null, railSegment: Number.isInteger(x.railSegment) ? x.railSegment : null, railT: Number.isFinite(Number(x.railT)) ? Math.max(0, Math.min(1, Number(x.railT))) : null, railKey2: typeof x.railKey2 === 'string' ? x.railKey2 : null, railSegment2: Number.isInteger(x.railSegment2) ? x.railSegment2 : null, railT2: Number.isFinite(Number(x.railT2)) ? Math.max(0, Math.min(1, Number(x.railT2))) : null, rot: Number.isFinite(Number(x.rot)) ? Number(x.rot) : 0, w: clampWH(Number(x.w) || 13), h: clampWH(Number(x.h) || 8), side: x.side === 1 || x.side === -1 ? x.side : 1 }));
  s.exits = s.exits.map((x, i) => ({ ...x, name: typeof x.name === 'string' && x.name.trim() ? x.name.trim() : `Exit ${i + 1}`, modes: [...new Set((Array.isArray(x.modes) ? x.modes : []).filter(mode => ['road', 'walk', 'rail'].includes(mode)))] }));
  s.parking = s.parking.map(x => ({ ...x, w: clampWH(Number(x.w) || 22), h: clampWH(Number(x.h) || 9), rot: Number.isFinite(Number(x.rot)) ? Number(x.rot) : 0, capacity: Math.max(2, Math.min(20, Math.round(Number(x.capacity) || 6))) }));
  s.simulation = normalizeSimulation(s.simulation);
  const okPt = p => Array.isArray(p) && isFinite(p[0]) && isFinite(p[1]);
  const cleanLn = l => (Array.isArray(l) ? l.filter(okPt) : []);
  const validLine = l => l.length >= 2 && !(l.length === 2 && distMeters(l[0][0], l[0][1], l[1][0], l[1][1]) < 0.5);   // валидная линия: >=2 точек и не «дважды одна точка»
  ['roads', 'rails', 'paths', 'alleys'].forEach(k => { s[k] = (s[k] || []).map(cleanLn).filter(validLine); });   // выкинуть битые точки/вырожденные линии
  s.plannedLines = undefined;                                                                                    // фича «пунктир-план» удалена, старые данные не нужны
  s.buildings = (s.buildings || []).filter(b => b && isFinite(b.lat) && isFinite(b.lng));                                  // выкинуть постройки с битыми координатами (ломали сим и рендер)
  s.lights = s.lights.filter(l => l && isFinite(l.lat) && isFinite(l.lng));
  bindLineMetadata(s);
  return s;
}
let state = load();
function load() {
  const mode = localStorage.getItem('ghostnation:mode');                // локальный мир хранится в своём ключе в зависимости от режима
  const keys = mode === 'mp' ? [MP_STORE, STORE_KEY] : [STORE_KEY, MP_STORE];
  for (const key of keys) {
    try {
      const r = localStorage.getItem(key);
      if (r) return migrate(Object.assign(freshState(), JSON.parse(r)));
    } catch (e) { console.warn(e); }
  }
  return freshState();
}
let storageWarned = false;
function save() {
  try { syncLineMetadata(); localStorage.setItem(isMP() ? MP_STORE : STORE_KEY, JSON.stringify(state)); }
  catch (e) {
    console.warn(e);
    if (!storageWarned) { storageWarned = true; try { flash('Не удалось сохранить в браузере — экспортируйте страну в файл', true); } catch (_) {} }
  }
  if (isMP()) mpSyncSave();
}

/* ════════════════ UNDO ════════════════ */
let undoStack = [], undoBytes = 0;
const UNDO_MAX_STEPS = 60, UNDO_MAX_BYTES = 24 * 1024 * 1024;
function pushUndo() {
  const snap = JSON.stringify(state);
  undoStack.push(snap); undoBytes += snap.length;
  while (undoStack.length > UNDO_MAX_STEPS || (undoBytes > UNDO_MAX_BYTES && undoStack.length > 1)) {
    const old = undoStack.shift(); undoBytes -= old.length;
  }
  updateUndoBtn();
}
function undo() {
  if (!undoStack.length) return;
  const prev = undoStack.pop(); undoBytes = Math.max(0, undoBytes - prev.length);
  state = Object.assign(freshState(), JSON.parse(prev));
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
const offset = (lat, lng, eM, nM) => [lat + nM / MPD_LAT, lng + eM / mPerDegLng(lat)];
const mpp = () => 40075016.686 * Math.cos(map.getCenter().lat * Math.PI / 180) / Math.pow(2, map.getZoom() + 8);
const mToPx = m => m / mpp();

/* ════════════════ MAP ════════════════ */
let map, territory = null;
let buildLayer, roadLayer, pathLayer, railLayer, crossLayer, editLayer, alleyLayer, districtLayer, zebraLayer, lightLayer, countryLabelLayer, transportLayer;
let layers = {}, currentLayer = 'esri', lastMouse = null, cameraRefreshFrame = 0;
function refreshCameraLineStyles() {
  cameraRefreshFrame = 0;
  if (!map) return;
  [roadLayer, alleyLayer, pathLayer, railLayer].forEach(g => g && g.eachLayer(l => {
    if (l._mWidth != null) l.setStyle({ weight: Math.max(1, mToPx(l._mWidth)) });
    if (typeof l.redraw === 'function') l.redraw();
  }));
}
function scheduleCameraLineRefresh() {
  if (cameraRefreshFrame) return;
  cameraRefreshFrame = requestAnimationFrame(refreshCameraLineStyles);
}

function initMap() {
  map = L.map('map', { zoomControl: false, attributionControl: true, worldCopyJump: true, maxZoom: 22, zoomSnap: 0, zoomDelta: 0.9, wheelPxPerZoomLevel: 45, zoomAnimation: true }).setView([state.view.lat, state.view.lng], state.view.zoom);   // zoomSnap:0 — плавный зум без рывков; maxZoom 22 — можно ближе
  [['pane-territory', 410], ['pane-rail', 411], ['pane-district', 412], ['pane-dirt', 413], ['pane-path', 415], ['pane-alley', 417], ['pane-lines', 420], ['pane-cross', 425], ['pane-builds', 430], ['pane-edit', 440]]
    .forEach(([n, z]) => { map.createPane(n); map.getPane(n).style.zIndex = z; });
  L.control.zoom({ position: 'topright' }).addTo(map);
  layers.esri = L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', { maxZoom: 22, maxNativeZoom: 19, attribution: 'Esri · GhostNation' });   // апскейл тайлов выше 19 — можно подъехать вплотную
  layers.google = L.tileLayer('https://mt{s}.google.com/vt/lyrs=s&x={x}&y={y}&z={z}', { maxZoom: 22, maxNativeZoom: 20, subdomains: ['0', '1', '2', '3'], attribution: 'Google · GhostNation' });
  layers[currentLayer].addTo(map);
  map.on('move', () => { scheduleCameraLineRefresh(); scheduleMpWorldLoad(); });
  map.on('zoom', () => { scheduleCameraLineRefresh(); scheduleMpWorldLoad(); });
  map.on('moveend', () => { scheduleCameraLineRefresh(); scheduleMpWorldLoad(0); if (sim.follow) return; if (isMP()) return; const c = map.getCenter(); state.view = { lat: c.lat, lng: c.lng, zoom: map.getZoom() }; save(); });
  map.on('zoomend', () => { scheduleCameraLineRefresh(); scheduleMpWorldLoad(0); renderCountryLabels(); });
  map.on('click', onMapClick);
  map.on('dblclick', e => {
    if (!draw.active) return;
    if (e.originalEvent) { e.originalEvent.preventDefault(); e.originalEvent.stopPropagation(); }
    finishDraw(true);
  });
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
  if (stationAssign) { stationAssign = null; renderTransport(); }   // сброс режима присваивания второго пути
  activeTool = (activeTool === tool) ? null : tool;
  if (activeTool === 'district' && (!state.border || state.border.length < 3)) { setToolIdle(); flash('Сначала нарисуй границу страны — затем можно делить её на районы', true); return; }
  document.querySelectorAll('.tool[data-tool]').forEach(b => b.classList.toggle('active', b.dataset.tool === activeTool));
  const m = document.getElementById('map');
  m.classList.toggle('drawing', ['house', 'shop', 'tree', 'light', 'crosswalk', 'station', 'parking', 'exit'].includes(activeTool));
  m.classList.toggle('erasing', activeTool === 'erase');
  m.classList.toggle('selecting', ['select', 'split'].includes(activeTool));
  if (activeTool === 'borders') { if (state.border && state.border.length >= 3) editBorder(); else startDraw('borders'); }   // граница есть → редактируем, нет → рисуем
  else if (['road', 'road-oneway', 'dirt', 'dirt-oneway', 'rail', 'path', 'alley', 'alley-oneway', 'district'].includes(activeTool)) startDraw(activeTool);
}
function setToolIdle() { activeTool = null; document.querySelectorAll('.tool[data-tool]').forEach(b => b.classList.remove('active')); document.getElementById('map').classList.remove('drawing', 'erasing', 'selecting'); }

/* ════════════════ DRAW ENGINE ════════════════ */
const draw = { active: false, mode: null, points: [], stationPoints: [], preview: null, rubber: null, handles: [] };
const DRIVE_DRAW_MODES = ['road', 'road-oneway', 'dirt', 'dirt-oneway', 'alley', 'alley-oneway'];
const STATION_ACCESS_DRAW_MODES = [...DRIVE_DRAW_MODES, 'path'];
const LINE_STYLE = { road: '#fff', 'road-oneway': '#fff', dirt: '#b98a5e', 'dirt-oneway': '#b98a5e', rail: '#d0d0d0', path: '#e9dec6', alley: '#cfcfcf', 'alley-oneway': '#cfcfcf' };
function isDriveDrawMode(mode) { return DRIVE_DRAW_MODES.includes(mode); }
function isStationAccessDrawMode(mode) { return STATION_ACCESS_DRAW_MODES.includes(mode); }
function baseLineMode(mode) { return mode && mode.startsWith('alley') ? 'alley' : 'road'; }
function drawLineMeta(mode) { return { surface: mode && mode.startsWith('dirt') ? 'dirt' : 'paved', oneWay: Boolean(mode && mode.endsWith('-oneway')) }; }
const CONNECT_PX = 28; // небольшой допуск для автоматического соединения концов улиц
function startDraw(mode) {
  draw.active = true; draw.mode = mode; draw.points = []; draw.stationPoints = []; draw.handles = [];
  if (map.doubleClickZoom) map.doubleClickZoom.disable();
  if (mode === 'borders') draw.preview = L.polygon([], { pane: 'pane-territory', color: state.color, weight: 2.5, fillColor: state.color, fillOpacity: .15, dashArray: '6 5' }).addTo(map);
  else if (mode === 'district') draw.preview = L.polygon([], { pane: 'pane-district', color: '#F5A623', weight: 2, fillColor: '#F5A623', fillOpacity: .15, dashArray: '6 5' }).addTo(map);
  else draw.preview = L.polyline([], { pane: 'pane-lines', color: LINE_STYLE[mode], weight: mode === 'path' ? 3 : 4, dashArray: '6 6' }).addTo(map);
  draw.rubber = L.polyline([], { pane: 'pane-lines', color: state.color, weight: 1.6, opacity: .7, dashArray: '4 5', interactive: false }).addTo(map);
  document.getElementById('map').classList.add('drawing');
  document.getElementById('draw-bar').classList.remove('hidden');
  updateDrawVisual();
  updateDrawHint();
}
function updateDrawVisual() {
  if (!draw.preview || !draw.rubber) return;
  draw.preview.setStyle({ color: LINE_STYLE[draw.mode], dashArray: '6 6', opacity: .85 });
  draw.rubber.setStyle({ color: state.color, dashArray: '4 5' });
}
function drawPointAt(latlng, originalEvent) {
  let point = latlng, snapped = false;
  const lockable = isDriveDrawMode(draw.mode) || ['rail', 'path'].includes(draw.mode);
  if (lockable && originalEvent && originalEvent.shiftKey && draw.points.length) {
    const anchor = map.latLngToLayerPoint(draw.points[draw.points.length - 1]);
    const raw = map.latLngToLayerPoint(point), dx = raw.x - anchor.x, dy = raw.y - anchor.y;
    const length = Math.hypot(dx, dy);
    if (length > 0) {
      const angle = Math.round(Math.atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4);
      point = map.layerPointToLatLng(L.point(anchor.x + Math.cos(angle) * length, anchor.y + Math.sin(angle) * length));
    }
  }
  if (lockable) { const s = snapDrawLine(point); if (s) { point = s; snapped = true; } }
  return { point, snapped };
}
function addVertex(latlng, originalEvent) {
  const prepared = drawPointAt(latlng, originalEvent);
  latlng = prepared.point;
  const station = prepared.snapped && isStationAccessDrawMode(draw.mode) ? stationAtEntry(latlng) : null;
  addDrawVertex(latlng, prepared.snapped, station);
  draw.preview.setLatLngs(draw.points);
  updateDrawHint();
}
function addDrawVertex(latlng, snapped = false, station = null) {
  const index = draw.points.length;
  draw.points.push(latlng);
  draw.handles.push(L.marker(latlng, { pane: 'markerPane', interactive: false, keyboard: false, icon: L.divIcon({ className: '', html: `<div class="vertex-dot${snapped ? ' snapped' : ''}${station ? ' station-endpoint' : ''}"></div>`, iconSize: [12, 12], iconAnchor: [6, 6] }) }).addTo(map));
  if (station) draw.stationPoints.push({ index, point: [latlng.lat, latlng.lng] });
}
function onMapMove(e) { if (draw.active && draw.points.length) draw.rubber.setLatLngs([draw.points[draw.points.length - 1], drawPointAt(e.latlng, e.originalEvent).point]); if (activeTool === 'station') stationPreview(e.latlng); }
function undoVertex() { if (!draw.points.length) return; const index = draw.points.length - 1; draw.points.pop(); draw.stationPoints = draw.stationPoints.filter(x => x.index !== index); const h = draw.handles.pop(); if (h) map.removeLayer(h); draw.preview.setLatLngs(draw.points); if (!draw.points.length) draw.rubber.setLatLngs([]); updateDrawHint(); }
function finishDraw(fromDoubleClick) {
  if (fromDoubleClick && draw.points.length > 1) {
    const last = draw.points[draw.points.length - 1], prev = draw.points[draw.points.length - 2];
    if (map.distance(last, prev) < Math.max(1, mpp() * 3)) undoVertex();
  }
  const min = (draw.mode === 'borders' || draw.mode === 'district') ? 3 : 2;
  if (draw.points.length < min) return;
  const pts = draw.points.map(p => [p.lat, p.lng]);
  const drawMode = draw.mode;
  const stationPoints = draw.stationPoints.map(x => ({ index: x.index, point: x.point.slice() }));
  if (draw.mode === 'district') {
    if (!state.border) { flash('Сначала проведи границы страны', true); return; }
    if (!pts.every(p => pointInPoly(p[0], p[1], state.border))) { flash('Район — только внутри границ', true); return; }
  }
  pushUndo();
  if (isDriveDrawMode(draw.mode) || ['rail', 'path'].includes(draw.mode)) {
    stationPoints.forEach(({ index, point }) => { if (index < pts.length) pts[index] = point; });
    connectNetworkLine(pts, true);
  }
  if (draw.mode === 'borders') { state.border = pts; renderTerritory(); if (isMP()) mpClaim(); }
  else if (isDriveDrawMode(draw.mode) && baseLineMode(draw.mode) === 'road') { state.roads.push(pts); setLineMeta(pts, drawLineMeta(draw.mode)); repairNetworkConnections(true, stationPoints.map(x => x.point), [pts]); setLineWalk(pts, stationPoints.length ? 'both' : 'none'); renderRoads(); renderCrossings(); renderZebras(); if (!stationPoints.length) openWalkBar(pts); }
  else if (draw.mode === 'rail') { state.rails.push(pts); repairNetworkConnections(true, [], [pts]); renderRails(); renderCrossings(); }
  else if (isDriveDrawMode(draw.mode) && baseLineMode(draw.mode) === 'alley') { state.alleys.push(pts); setLineMeta(pts, drawLineMeta(draw.mode)); repairNetworkConnections(true, stationPoints.map(x => x.point), [pts]); setLineWalk(pts, 'none'); renderAlleys(); renderCrossings(); if (!stationPoints.length) openWalkBar(pts); }
  else if (draw.mode === 'district') { state.districts.push({ pts, color: FLAG_COLORS[randInt(FLAG_COLORS.length)] }); renderDistricts(); }
  else { state.paths.push(pts); repairNetworkConnections(true, stationPoints.map(x => x.point), [pts]); renderPaths(); }
  save(); renderTransport();
  if (stationPoints.length) refreshStationAccessInRunningSim(pts, drawMode);
  clearDraw(); setToolIdle(); updateStats();
}
function cancelDraw() { clearDraw(); }
function clearDraw() {
  if (draw.preview) map.removeLayer(draw.preview);
  if (draw.rubber) map.removeLayer(draw.rubber);
  draw.handles.forEach(h => map.removeLayer(h));
  Object.assign(draw, { active: false, mode: null, points: [], stationPoints: [], preview: null, rubber: null, handles: [] });
  if (map.doubleClickZoom) map.doubleClickZoom.enable();
  document.getElementById('draw-bar').classList.add('hidden');
  document.getElementById('map').classList.remove('drawing');
}
function updateDrawHint() {
  const hint = document.getElementById('draw-hint'), done = document.getElementById('draw-done'), n = draw.points.length;
  if (draw.mode === 'borders' || draw.mode === 'district') {
    done.disabled = n < 3;
    const prefix = draw.mode === 'district' ? 'Район · точки только внутри границы' : 'Граница страны';
    hint.textContent = `${prefix}: ${n} ${plural(n, 'точка', 'точки', 'точек')}` + (n >= 3 ? ' · ~' + fmtArea(geodesicArea(draw.points)) : '') + ' · Готово или Enter — завершить';
  }
  else { const labels = { road: 'Дорога', 'road-oneway': 'Дорога →', dirt: 'Грунтовка', 'dirt-oneway': 'Грунтовка →', alley: 'Проезд', 'alley-oneway': 'Проезд →', rail: 'Жд', path: 'Тропинка' }, lbl = labels[draw.mode] || 'Линия'; done.disabled = n < 2; hint.textContent = `${lbl}: ${n} ${plural(n, 'точка', 'точки', 'точек')}` + (n >= 2 ? ' · ' + fmtLen(pathLength(draw.points)) : '') + ((isDriveDrawMode(draw.mode) || ['rail', 'path'].includes(draw.mode)) ? ' · Shift: ровный угол · соединение с дорогами · двойной клик: готово' : ' · двойной клик: готово') + (isStationAccessDrawMode(draw.mode) ? ' · клик по станции: зелёная привязка' : ''); }
}

/* ════════════════ SNAP ════════════════ */
function projSeg(p, a, b) { const dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy; if (l2 === 0) return a; let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2; t = Math.max(0, Math.min(1, t)); return L.point(a.x + t * dx, a.y + t * dy); }
function networkLines(includePaths = false) { return state.roads.concat(state.rails, state.alleys, includePaths ? state.paths : []); }
function snapLineInfo(latlng, radius = SNAP_PX, excludeLine = null, includePaths = false, candidates = null, endpointsOnly = false) { // вершины приоритетно, затем любой сегмент
  const p = map.latLngToLayerPoint(latlng), lines = candidates || networkLines(includePaths);
  let bestV = null, bestVD = radius * 1.7;
  if (endpointsOnly) {                              // только концы линий (для притягивания концов дорог)
    for (const line of lines) {
      if (line === excludeLine || line.length < 2) continue;
      for (const idx of [0, line.length - 1]) {
        const v = map.latLngToLayerPoint(L.latLng(line[idx][0], line[idx][1])), d = p.distanceTo(v);
        if (d < bestVD) { bestVD = d; bestV = { point: L.latLng(line[idx][0], line[idx][1]), line, vertex: idx }; }
      }
    }
    return bestV || null;
  }
  for (const line of lines) {
    if (line === excludeLine) continue;
    for (let i = 0; i < line.length; i++) {
      const v = map.latLngToLayerPoint(L.latLng(line[i][0], line[i][1])), d = p.distanceTo(v);
      if (d < bestVD) { bestVD = d; bestV = { point: L.latLng(line[i][0], line[i][1]), line, vertex: i }; }
    }
  }
  if (bestV) return bestV;
  let best = null, bestD = radius;
  for (const line of lines) {
    if (line === excludeLine) continue;
    for (let i = 1; i < line.length; i++) {
      const a = map.latLngToLayerPoint(L.latLng(line[i - 1][0], line[i - 1][1])), b = map.latLngToLayerPoint(L.latLng(line[i][0], line[i][1])), pr = projSeg(p, a, b), d = p.distanceTo(pr);
      if (d < bestD) { bestD = d; best = { point: map.layerPointToLatLng(pr), line, segment: i - 1 }; }
    }
  }
  return best;
}
function snapLine(latlng) { const hit = snapLineInfo(latlng); return hit ? hit.point : null; }
function snapDrawLine(latlng) {
  const stations = isStationAccessDrawMode(draw.mode) ? stationSnapLines() : [];
  const candidates = draw.mode === 'path' ? pedestrianBaseLines().concat(stations) : networkLines(true).concat(stations);
  // Полный магнит при рисовании: липнет и к концам, и к середине линий (примыкание в любом месте).
  const hit = snapLineInfo(latlng, SNAP_PX, null, true, candidates, false);
  return hit ? hit.point : null;
}
function insertNetworkVertex(line, point) {
  if (line.some(p => distMeters(p[0], p[1], point.lat ?? point[0], point.lng ?? point[1]) < 1)) return false;
  const lat = point.lat ?? point[0], lng = point.lng ?? point[1];
  let best = { index: -1, distance: Infinity };
  for (let i = 1; i < line.length; i++) {
    const d = pointSegDistM(lat, lng, line[i - 1], line[i]);
    if (d < best.distance) best = { index: i - 1, distance: d };
  }
  if (best.index < 0 || best.distance > 2) return false;
  line.splice(best.index + 1, 0, [lat, lng]);
  return true;
}
function connectNetworkLine(points, includePaths = false) {
  const network = networkLines(includePaths);
  let changed = false;
  for (const line of network) {
    for (let i = 1; i < points.length; i++) {
      for (let j = 1; j < line.length; j++) {
        const hit = segInter(points[i - 1], points[i], line[j - 1], line[j]);
        if (!hit) continue;
        // Разрезаем существующую линию в точке пересечения (нужно для сети машин/поездов),
        // но НЕ вставляем вершину в рисуемые points: конец новой линии не должен «липнуть» к середине.
        changed = insertNetworkVertex(line, hit) || changed;
      }
    }
  }
  return changed;
}
function repairNetworkConnections(includePaths = false, protectedPoints = [], onlyLines = null) {
  const network = networkLines(includePaths);
  let changed = false;

  // Разрезаем обе линии в каждой настоящей точке пересечения. Без этого
  // визуальный крест не становился узлом сети для машин и пешеходов.
  // Концы линий никогда не двигаем: линия остаётся там, где её отпустили.
  for (let a = 0; a < network.length; a++) for (let b = a + 1; b < network.length; b++) {
    const left = network[a], right = network[b], hits = [];
    for (let i = 1; i < left.length; i++) for (let j = 1; j < right.length; j++) {
      const hit = segInter(left[i - 1], left[i], right[j - 1], right[j]);
      if (hit) hits.push(hit);
    }
    for (const hit of hits) {
      if (insertNetworkVertex(left, hit)) changed = true;
      if (insertNetworkVertex(right, hit)) changed = true;
    }
  }
  return changed;
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
  if (draw.active) {
    if (draw.mode === 'path') {                        // клик по дому в режиме тропинки — проложить ко входу
      const hit = buildingAtPoint(e.latlng, 2);
      if (hit) {
        pushUndo();
        const line = addWalkway(hit, true);
        if (line) { renderPaths(); save(); flash('Тропинка от входа проложена к сети'); }
        else flash('Не нашёл, куда вести тропинку', true);
        return;
      }
    }
    addVertex(e.latlng, e.originalEvent); return;
  }
  if (activeTool === 'split') { splitRoadAt(e.latlng); return; }
  if (activeTool === 'select') { deselect(); return; }
  if (activeTool === 'station') {
    if (stationAssign) {                               // режим присваивания второго пути
      const target = stationAssign; stationAssign = null;
      assignStationSecondRail(target, e.latlng); renderTransport();
      return;
    }
    placeStation(e.latlng); return;
  }
  if (activeTool === 'parking') { placeParking(e.latlng); return; }
  if (activeTool === 'exit') { placeExit(e.latlng); return; }
  if (activeTool === 'light') {
    const X = nearestIntersection(e.latlng);
    if (!X) { flash('Светофор ставится на перекрёстке', true); return; }
    if (!state.lights.some(l => distMeters(l.lat, l.lng, X[0], X[1]) < 2)) { pushUndo(); state.lights.push({ lat: X[0], lng: X[1] }); save(); renderLights(); }
    return;
  }
  if (activeTool === 'crosswalk') {
    placeCrosswalk(e.latlng);
    return;
  }
  if (['house', 'shop', 'tree'].includes(activeTool)) placeBuilding(activeTool, e.latlng);
}
function bRadius(b) { return b.type === 'tree' ? clampR(b.r ?? DEF.tree.r) : Math.hypot(clampWH(b.w ?? DEF[b.type].w) / 2, clampWH(b.h ?? DEF[b.type].h) / 2); }
function buildingAtPoint(latlng, pad = 1) {        // постройка под кликом (без деревьев)
  let best = null, bd = Infinity;
  for (const b of state.buildings) {
    if (b.type === 'tree' || !isFinite(b.lat) || !isFinite(b.lng)) continue;
    const d = distMeters(latlng.lat, latlng.lng, b.lat, b.lng);
    if (d < bRadius(b) + pad && d < bd) { bd = d; best = b; }
  }
  return best;
}
function distMeters(la1, ln1, la2, ln2) { const E = (ln2 - ln1) * mPerDegLng(la1), N = (la2 - la1) * MPD_LAT; return Math.hypot(E, N); }
const LINE_KINDS = ['roads', 'alleys', 'paths', 'rails'];
function lineHalfWidth(kind) { return ((kind === 'rails' ? LINE_M.rail : kind === 'paths' ? LINE_M.path : kind === 'alleys' ? LINE_M.alley : LINE_M.road) / 2) + 0.3; }
function lineSegDistMin(lat, lng, line) {
  let best = Infinity;
  for (let i = 1; i < line.length; i++) best = Math.min(best, pointSegDistM(lat, lng, line[i - 1], line[i]));
  return best;
}
function nearestAnyLineDist(lat, lng) {
  let best = Infinity;
  for (const kind of LINE_KINDS) for (const line of state[kind] || []) best = Math.min(best, lineSegDistMin(lat, lng, line));
  return best;
}
// занятость места ЛЮБЫМ объектом: постройки, станции, парковки, съезды, светофоры, переходы
function overlapsAt(lat, lng, radius, exclude) {
  for (const o of state.buildings) { if (o === exclude) continue; if (distMeters(lat, lng, o.lat, o.lng) < radius + bRadius(o)) return true; }
  for (const s of state.stations || []) if (distMeters(lat, lng, s.lat, s.lng) < radius + 9) return true;
  for (const p of state.parking || []) if (distMeters(lat, lng, p.lat, p.lng) < radius + Math.max(p.w || 22, p.h || 9) / 2) return true;
  for (const x of state.exits || []) if (distMeters(lat, lng, x.lat, x.lng) < radius + 6) return true;
  for (const l of state.lights || []) if (distMeters(lat, lng, l.lat, l.lng) < radius + 2.5) return true;
  for (const c of state.crosswalks || []) if (distMeters(lat, lng, c.lat, c.lng) < radius + 4) return true;
  return false;
}
function insideBuilding(lat, lng) {
  for (const o of state.buildings) if (distMeters(lat, lng, o.lat, o.lng) < bRadius(o) + 1) return true;
  for (const s of state.stations || []) if (distMeters(lat, lng, s.lat, s.lng) < 9) return true;
  for (const p of state.parking || []) if (distMeters(lat, lng, p.lat, p.lng) < Math.max(p.w || 22, p.h || 9) / 2) return true;
  for (const x of state.exits || []) if (distMeters(lat, lng, x.lat, x.lng) < 6) return true;
  return false;
}
function freeSpot(lat, lng, radius) {
  for (let ring = 1; ring <= 9; ring++) { const dist = ring * (radius * 2 + 3); for (let k = 0; k < 8; k++) { const ang = k / 8 * 2 * Math.PI, ll = offset(lat, lng, Math.cos(ang) * dist, Math.sin(ang) * dist); if (!overlapsAt(ll[0], ll[1], radius) && nearestAnyLineDist(ll[0], ll[1]) >= LINE_M.road / 2 + radius * 0.7) return { lat: ll[0], lng: ll[1] }; } }
  return { lat, lng };
}
function pointSegDistM(plat, plng, a, b) {     // metres from point to road segment
  const mlng = mPerDegLng(a[0]), bx = (b[1] - a[1]) * mlng, by = (b[0] - a[0]) * MPD_LAT;
  const px = (plng - a[1]) * mlng, py = (plat - a[0]) * MPD_LAT, l2 = bx * bx + by * by;
  let t = l2 ? (px * bx + py * by) / l2 : 0; t = Math.max(0, Math.min(1, t));
  return Math.hypot(px - t * bx, py - t * by);
}
function buildingHitsRoad(b) {                  // касание ЛЮБОЙ линии: дороги, переулки, тропинки, жд
  if (b.type === 'tree') {
    const r = clampR(b.r ?? DEF.tree.r);
    return LINE_KINDS.some(kind => (state[kind] || []).some(line => lineSegDistMin(b.lat, b.lng, line) < lineHalfWidth(kind) + r * 0.6));
  }
  const pts = [[b.lat, b.lng], ...rectCorners(b)]; const dr = doorRect(b); pts.push(dr[2], dr[3]);
  for (const kind of LINE_KINDS) for (const line of state[kind] || [])
    for (let i = 1; i < line.length; i++)
      for (const p of pts) if (pointSegDistM(p[0], p[1], line[i - 1], line[i]) < lineHalfWidth(kind)) return true;
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
function settleAll() { pushUndo(); settlePass(25); ensureWalkways(false); save(); renderBuildings(); renderPaths(); updateStats(); flash('Здания подтянуты к дороге'); }

/* ════════════════ AUTO-GENERATION ALONG A ROAD ════════════════ */
function walkwayNearEntry(ent) {         // уже есть тропинка от этого входа?
  return state.paths.find(p => (distMeters(p[0][0], p[0][1], ent[0], ent[1]) < 1.5 || distMeters(p[p.length - 1][0], p[p.length - 1][1], ent[0], ent[1]) < 1.5)) || null;
}
function pedestrianLineAt(point, exclude) {   // ближайшая линия пешеходной сети к точке
  let best = null, bd = Infinity;
  for (const line of pedestrianBaseLines()) {
    if (line === exclude) continue;
    for (let i = 1; i < line.length; i++) {
      const pr = projOnSegLL(point, line[i - 1], line[i]), d = distMeters(point[0], point[1], pr[0], pr[1]);
      if (d < bd) { bd = d; best = { point: pr, dist: d }; }
    }
  }
  return best;
}
function addWalkway(b, force = false) {  // тропинка от входа дома до ближайшей пешеходной линии
  if (!b || b.type === 'tree') return null;
  const ent = doorEntry(b);
  if (!force && walkwayNearEntry(ent)) return null;
  const target = pedestrianLineAt(ent);
  if (!target || target.dist > 90 || target.dist < 0.6) return null;
  if (!isFinite(ent[0]) || !isFinite(ent[1]) || !isFinite(target.point[0]) || !isFinite(target.point[1])) return null;
  const line = [ent, target.point];
  state.paths.push(line);
  return line;
}
function ensureWalkways(saveAfter = true) {   // достроить недостающие тропинки от входов к сети
  let added = 0;
  for (const b of state.buildings) if (addWalkway(b)) added++;
  if (added) { renderPaths(); if (saveAfter) save(); }
  return added;
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
function doorEntry(b) {                 // точка входа: середина внешнего края крыльца
  const dr = doorRect(b);
  return [(dr[2][0] + dr[3][0]) / 2, (dr[2][1] + dr[3][1]) / 2];
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
function bPositionMids() {
  for (const m of borderEdit.mids) {
    if (m._borderPromoted) continue;
    const edge = Number.isInteger(m._borderEdge) ? m._borderEdge : borderEdit.mids.indexOf(m);
    if (state.border && edge >= 0 && edge < state.border.length) m.setLatLng(bMidPos(edge));
  }
}
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
    m._borderEdge = i;
    m.on('dragstart', e => {
      if (m._borderPromoted) return;
      pushUndo();
      const at = e && e.latlng ? e.latlng : (m.getLatLng ? m.getLatLng() : bMidPos(i));
      B.splice(i + 1, 0, [at.lat, at.lng]);
      m._borderPromoted = true; m._borderIndex = i + 1;
      for (const other of borderEdit.mids) {
        if (other === m || other._borderPromoted) continue;
        if (Number.isInteger(other._borderEdge) && other._borderEdge > i) other._borderEdge++;
      }
      m.setIcon(L.divIcon({ className: '', html: '<div class="edit-handle h-vert"></div>', iconSize: [15, 15], iconAnchor: [7.5, 7.5] }));
      if (territory) territory.setLatLngs(B);
    });
    m.on('drag', e => {
      const point = [e.latlng.lat, e.latlng.lng];
      if (!m._borderPromoted) {
        B.splice(i + 1, 0, point); m._borderPromoted = true; m._borderIndex = i + 1;
        for (const other of borderEdit.mids) {
          if (other === m || other._borderPromoted) continue;
          if (Number.isInteger(other._borderEdge) && other._borderEdge > i) other._borderEdge++;
        }
      }
      B[m._borderIndex] = point;
      if (territory) territory.setLatLngs(B);
    });
    m.on('dragend', e => {
      if (!m._borderPromoted) {
        const at = e && e.latlng ? e.latlng : (m.getLatLng ? m.getLatLng() : bMidPos(i));
        B.splice(i + 1, 0, [at.lat, at.lng]); m._borderPromoted = true; m._borderIndex = i + 1;
      }
      save(); renderTerritory(); bBuildHandles(); updateStats();
    });
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
function drawHouse(b, layer = buildLayer) {
  const corners = rectCorners(b), out = [], own = layer === buildLayer;
  if (b.type === 'shop') {
    out.push(L.polygon(corners, { pane: 'pane-builds', color: '#ffffff', weight: 4, fillColor: ROOF.shop.fill, fillOpacity: .95 }).addTo(layer));   // parapet
    out.push(L.polygon(insetRect(b, 0.66), { pane: 'pane-builds', color: '#173b6b', weight: 1, fillColor: '#2f6fc4', fillOpacity: .97 }).addTo(layer)); // roof field
    out.push(L.polygon(insetRect(b, 0.30), { pane: 'pane-builds', color: '#0e294e', weight: 1, fillColor: '#1d4f93', fillOpacity: .97 }).addTo(layer)); // rooftop unit
  } else {
    const f = roofFacets(b);
    out.push(L.polygon(f.slope1, { pane: 'pane-builds', color: ROOF.house.edge, weight: 1, fillColor: '#44c65a', fillOpacity: .97 }).addTo(layer));
    out.push(L.polygon(f.slope2, { pane: 'pane-builds', color: ROOF.house.edge, weight: 1, fillColor: '#2f9d43', fillOpacity: .97 }).addTo(layer));
    out.push(L.polygon(f.hip1, { pane: 'pane-builds', color: ROOF.house.edge, weight: 1, fillColor: '#23823a', fillOpacity: .97 }).addTo(layer));
    out.push(L.polygon(f.hip2, { pane: 'pane-builds', color: ROOF.house.edge, weight: 1, fillColor: '#23823a', fillOpacity: .97 }).addTo(layer));
    out.push(L.polyline(f.ridge, { pane: 'pane-builds', color: '#eafff0', weight: 1.8, opacity: .95 }).addTo(layer));
  }
  out.push(L.polygon(doorRect(b), { pane: 'pane-builds', color: '#7a4a12', weight: 1, fillColor: PORCH, fillOpacity: .95 }).addTo(layer));
  if (own) out.forEach(l => { l.on('click', e => onBuildClick(b, e)); l.on('mouseover', () => hoverBuilding(b)); l.on('mouseout', clearHover); });
  return out;
}
function drawTree(b, layer = buildLayer) {
  const c = L.circle([b.lat, b.lng], { pane: 'pane-builds', radius: clampR(b.r ?? DEF.tree.r), color: '#16551f', weight: 1, fillColor: '#2f9a44', fillOpacity: .9 }).addTo(layer);
  if (layer === buildLayer) { c.on('click', e => onBuildClick(b, e)); c.on('mouseover', () => hoverBuilding(b)); c.on('mouseout', clearHover); }
  return [c];
}
function renderBuildings() { buildLayer.clearLayers(); blMap.clear(); state.buildings.forEach(b => blMap.set(b, b.type === 'tree' ? drawTree(b) : drawHouse(b))); }
function updateBuildingGeom(b) { const old = blMap.get(b); if (old) old.forEach(l => buildLayer.removeLayer(l)); blMap.set(b, b.type === 'tree' ? drawTree(b) : drawHouse(b)); }
function onBuildClick(b, e) { if (activeTool === 'erase') { L.DomEvent.stop(e); removeBuilding(b); } else if (activeTool === 'select') { L.DomEvent.stop(e); selectBuilding(b); } }
function removeBuilding(b) { pushUndo(); if (selected === b) deselect(); clearHover(); state.buildings = state.buildings.filter(x => x !== b); save(); renderBuildings(); updateStats(); }

/* ════════════════ HOVER HIGHLIGHT ════════════════ */
function stationPreview(latlng) {                 // предпросмотр станции при наведении на ЖД (инструмент «станция»)
  const hit = nearestLinePointForGroups(latlng, ['rails']);
  if (!hit || hit.distance > Math.max(22, mToPx(LINE_M.rail) * 2.4)) { if (hoverHL) clearHover(); return; }
  const a = hit.line[hit.segment], b = hit.line[hit.segment + 1], segLen = distMeters(a[0], a[1], b[0], b[1]) || 1;
  const railT = Math.max(0, Math.min(1, distMeters(a[0], a[1], hit.point.lat, hit.point.lng) / segLen));
  const ref = { line: hit.line, seg: hit.segment, point: [hit.point.lat, hit.point.lng] };
  const side = stationSideOfPoint(ref, latlng);
  const pseudo = { lat: hit.point.lat, lng: hit.point.lng, railKey: roadKey(hit.line), railSegment: hit.segment, railT, rot: 0, side };
  const g = stationGeometry(pseudo);
  const access = stationAccessInfo(pseudo);
  clearHover();
  hoverPL = L.polygon(g.platformPoly, { pane: 'pane-edit', interactive: false, color: access ? '#42dc83' : '#ffffff', weight: 2, dashArray: '5 4', fillOpacity: .18, fillColor: access ? '#42dc83' : '#ffffff' }).addTo(map);
  hoverBL = L.polygon(rectCorners(g.building), { pane: 'pane-edit', interactive: false, color: '#ffffff', weight: 2, dashArray: '5 4', fill: false }).addTo(map);
  hoverHL = hoverPL;
}
let hoverHL = null, hoverPL = null, hoverBL = null;
function clearHover() { if (hoverHL) { map.removeLayer(hoverHL); hoverHL = null; } if (hoverPL) { map.removeLayer(hoverPL); hoverPL = null; } if (hoverBL) { map.removeLayer(hoverBL); hoverBL = null; } }
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
function nearestEditableLine(latlng) {
  const p = map.latLngToLayerPoint(latlng), candidates = [];
  for (const key of ['roads', 'alleys']) for (const line of state[key]) {
    for (let i = 1; i < line.length; i++) {
      const a = map.latLngToLayerPoint(L.latLng(line[i - 1][0], line[i - 1][1])), b = map.latLngToLayerPoint(L.latLng(line[i][0], line[i][1])), projection = projSeg(p, a, b), distance = p.distanceTo(projection);
      if (!candidates.length || distance < candidates[0].distance) candidates[0] = { key, line, segment: i - 1, point: map.layerPointToLatLng(projection), distance };
    }
  }
  return candidates[0] || null;
}
function splitRoadAt(latlng) {
  const hit = nearestEditableLine(latlng);
  if (!hit || hit.distance > Math.max(14, mToPx(Math.max(LINE_M.road, LINE_M.alley)) * 1.7)) { flash('Кликни по дороге или проезду', true); return; }
  const line = hit.line, i = hit.segment;
  if (map.distance(L.latLng(line[0][0], line[0][1]), hit.point) < 1.5 || map.distance(L.latLng(line[line.length - 1][0], line[line.length - 1][1]), hit.point) < 1.5) { flash('Здесь уже есть конец дороги', true); return; }
  const arr = state[hit.key], pos = arr.indexOf(line); if (pos < 0) return;
  pushUndo();
  const existing = line.findIndex((p, index) => index > 0 && index < line.length - 1 && map.distance(L.latLng(p[0], p[1]), hit.point) < 1.5);
  const point = existing > 0 ? [line[existing][0], line[existing][1]] : [hit.point.lat, hit.point.lng];
  const left = existing > 0 ? line.slice(0, existing + 1) : line.slice(0, i + 1).concat([point]);
  const right = existing > 0 ? line.slice(existing) : [point].concat(line.slice(i + 1));
  const meta = lineMeta(line), walk = lineWalk(line);
  setLineMeta(left, meta); setLineMeta(right, meta); setLineWalk(left, walk); setLineWalk(right, walk);
  arr.splice(pos, 1, left, right);
  repairNetworkConnections(true); save(); clearHover();
  hit.key === 'roads' ? renderRoads() : renderAlleys();
  renderCrossings(); renderZebras(); updateStats();
  flash('Дорога разделена на две');
}

/* ════════════════ RENDER: ROADS / PATHS / RAILS / CROSS ════════════════ */
function roadPx() { return Math.max(2.5, mToPx(LINE_M.road)); }
function railPx() { return Math.max(2.5, mToPx(LINE_M.rail)); }
function pathPx() { return Math.max(1.5, mToPx(LINE_M.path)); }
const tagW = (layer, m) => { layer._mWidth = m; return layer; };   // mark metre-width for zoom rescale
function lineWidthM(line) { const meta = lineMeta(line); if (meta.surface === 'dirt') return state.alleys.includes(line) ? Math.min(LINE_M.alley, DIRT_WIDTH_M) : DIRT_WIDTH_M; return state.alleys.includes(line) ? LINE_M.alley : LINE_M.road; }
function linePointAtDistance(line, distance) {
  let left = Math.max(0, distance);
  for (let i = 1; i < line.length; i++) {
    const a = line[i - 1], b = line[i], len = distMeters(a[0], a[1], b[0], b[1]);
    if (left <= len || i === line.length - 1) { const t = len ? Math.min(1, left / len) : 0; return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, i - 1]; }
    left -= len;
  }
  return [line[line.length - 1][0], line[line.length - 1][1], line.length - 2];
}
function addOneWayArrows(layer, line, color) {
  if (!lineMeta(line).oneWay) return;
  const pane = lineMeta(line).surface === 'dirt' ? 'pane-dirt' : 'pane-edit';
  const total = roadLen(line), count = total > 90 ? 2 : 1;
  for (let i = 1; i <= count; i++) {
    const at = linePointAtDistance(line, total * i / (count + 1)), seg = at[2], a = line[seg], b = line[seg + 1];
    const angle = Math.atan2((b[0] - a[0]) * MPD_LAT, (b[1] - a[1]) * mPerDegLng(a[0])) * 180 / Math.PI;
    L.marker([at[0], at[1]], { pane, interactive: false, keyboard: false, icon: L.divIcon({ className: 'road-direction', html: `<span style="color:${color};transform:rotate(${-angle}deg)">➜</span>`, iconSize: [20, 20], iconAnchor: [10, 10] }) }).addTo(layer);
  }
}
function addDirtDetails(layer, line, widthM) {
  const track = Math.max(.8, widthM * .22), trackW = Math.max(.7, mToPx(.32));
  for (const offsetM of [track, -track]) tagW(L.polyline(offsetLine(line, offsetM), { pane: 'pane-dirt', color: '#5c412f', weight: trackW, opacity: .72, lineCap: 'round', lineJoin: 'round', interactive: false }).addTo(layer), .32);
  tagW(L.polyline(line, { pane: 'pane-dirt', color: '#d1a273', weight: Math.max(.8, mToPx(.24)), opacity: .78, dashArray: '1 8', lineCap: 'round', interactive: false }).addTo(layer), .24);
}

function lineHandlers(layer, key, line) {
  layer.on('click', e => { if (activeTool !== 'erase') return; L.DomEvent.stop(e); eraseSegment(key, line, e.latlng); });
  layer.on('mousemove', e => hoverSeg(e.latlng, line));
  layer.on('mouseout', clearHover);
}
function renderRoads() {
  roadLayer.clearLayers();
  const sw = Math.max(2, mToPx(LINE_M.path + 0.6));
  state.roads.forEach(r => {
    const meta = lineMeta(r), widthM = lineWidthM(r), walk = lineWalk(r), sides = walk === 'both' ? [widthM / 2 + 1, -(widthM / 2 + 1)] : walk === 'left' ? [widthM / 2 + 1] : walk === 'right' ? [-(widthM / 2 + 1)] : [], w = Math.max(2.5, mToPx(widthM));
    sides.forEach(o => tagW(L.polyline(offsetLine(r, o), { pane: 'pane-path', color: '#b7b9bc', weight: sw, opacity: .92, interactive: false, lineCap: 'round' }).addTo(roadLayer), LINE_M.path + 0.6));   // тротуары по выбранным сторонам
    const surfaceColor = meta.surface === 'dirt' ? '#886548' : '#3b3f45', mainPane = meta.surface === 'dirt' ? 'pane-dirt' : 'pane-lines', asphalt = tagW(L.polyline(r, { pane: mainPane, color: surfaceColor, weight: w, opacity: .97, dashArray: meta.surface === 'dirt' ? '10 5' : null, lineCap: 'round', lineJoin: 'round' }).addTo(roadLayer), widthM);
    if (meta.surface === 'dirt') addDirtDetails(roadLayer, r, widthM);
    else tagW(L.polyline(r, { pane: 'pane-lines', color: meta.oneWay ? '#e5e7eb' : '#f2c200', weight: Math.max(1, w * 0.11), opacity: .9, dashArray: `${Math.max(4, w * 0.8)} ${Math.max(6, w * 1.3)}`, interactive: false }).addTo(roadLayer), widthM * 0.11);
    addOneWayArrows(roadLayer, r, meta.surface === 'dirt' ? '#f1c38c' : '#f2c200');
    asphalt.on('click', e => {
      if (activeTool === 'erase') { L.DomEvent.stop(e); eraseSegment('roads', r, e.latlng); }
      else if (activeTool === 'split') { L.DomEvent.stop(e); splitRoadAt(e.latlng); }
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
  alleyLayer.clearLayers(); const sw = Math.max(2, mToPx(LINE_M.path + 0.6));
  state.alleys.forEach(r => {
    const meta = lineMeta(r), widthM = lineWidthM(r), walk = lineWalk(r), sides = walk === 'both' ? [widthM / 2 + 1, -(widthM / 2 + 1)] : walk === 'left' ? [widthM / 2 + 1] : walk === 'right' ? [-(widthM / 2 + 1)] : [], w = Math.max(2, mToPx(widthM));
    sides.forEach(o => tagW(L.polyline(offsetLine(r, o), { pane: 'pane-path', color: '#b7b9bc', weight: sw, opacity: .9, interactive: false, lineCap: 'round' }).addTo(alleyLayer), LINE_M.path + 0.6));
    const mainPane = meta.surface === 'dirt' ? 'pane-dirt' : 'pane-alley', ln = tagW(L.polyline(r, { pane: mainPane, color: meta.surface === 'dirt' ? '#886548' : '#54585f', weight: w, opacity: .96, dashArray: meta.surface === 'dirt' ? '10 5' : null, lineCap: 'round', lineJoin: 'round' }).addTo(alleyLayer), widthM);
    if (meta.surface === 'dirt') addDirtDetails(alleyLayer, r, widthM);
    addOneWayArrows(alleyLayer, r, meta.surface === 'dirt' ? '#f1c38c' : '#f2c200');
    ln.on('click', e => {
      if (activeTool === 'erase') { L.DomEvent.stop(e); eraseSegment('alleys', r, e.latlng); }
      else if (activeTool === 'split') { L.DomEvent.stop(e); splitRoadAt(e.latlng); }
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
  const out = [], total = roadLen(latlngs);
  for (let d = spacingM * .5; d < total; d += spacingM) {
    const at = linePointAtDistance(latlngs, d), i = at[2], a = latlngs[i], b = latlngs[i + 1], E = (b[1] - a[1]) * mPerDegLng(a[0]), N = (b[0] - a[0]) * MPD_LAT, len = Math.hypot(E, N) || 1, px = -N / len, py = E / len;
    out.push([offset(at[0], at[1], px * halfM, py * halfM), offset(at[0], at[1], -px * halfM, -py * halfM)]);
  }
  return out;
}
function renderRails() {
  railLayer.clearLayers(); const w = railPx(), gravelW = Math.max(2.5, w), gravelTextureW = Math.max(1.3, w * .62), tieW = Math.max(1.8, w * .28), railW = Math.max(1, w * .18), halfBed = LINE_M.rail * .5, gauge = LINE_M.rail * .34;
  state.rails.forEach(path => {
    const bed = tagW(L.polyline(path, { pane: 'pane-rail', color: '#47413b', weight: gravelW, opacity: .98, lineCap: 'round', lineJoin: 'round', interactive: false }).addTo(railLayer), LINE_M.rail);
    tagW(L.polyline(path, { pane: 'pane-rail', color: '#85735f', weight: gravelTextureW, opacity: .7, dashArray: '1.5 3.5', lineCap: 'round', lineJoin: 'round', interactive: false }).addTo(railLayer), LINE_M.rail * .62);
    railTies(path, halfBed, 5.5).forEach(seg => tagW(L.polyline(seg, { pane: 'pane-rail', color: '#b7a486', weight: tieW, opacity: .94, lineCap: 'round', interactive: false }).addTo(railLayer), LINE_M.rail * .28));
    [gauge, -gauge].forEach(g => tagW(L.polyline(offsetLine(path, g), { pane: 'pane-rail', color: '#e1d9cc', weight: railW, opacity: .98, lineCap: 'round', lineJoin: 'round', interactive: false }).addTo(railLayer), LINE_M.rail * .18));
  });
  state.rails.forEach(r => {                            // кликабельное полотно — по оригинальным линиям (стирание сегмента)
    const bed = tagW(L.polyline(r, { pane: 'pane-rail', color: '#47413b', weight: Math.max(gravelW, 4), opacity: 0, lineCap: 'round', lineJoin: 'round' }).addTo(railLayer), LINE_M.rail);
    bed.on('click', e => { if (activeTool !== 'erase') return; L.DomEvent.stop(e); eraseSegment('rails', r, e.latlng); });
    bed.on('mousemove', e => hoverSeg(e.latlng, r)); bed.on('mouseout', clearHover);
  });
}
function eraseSegment(key, line, latlng) {
  pushUndo();
  const arr = state[key], pos = arr.indexOf(line); if (pos < 0) return;
  const i = nearestSegIdx(latlng, line), before = line.slice(0, i + 1), after = line.slice(i + 1), repl = [];
  const meta = key === 'roads' || key === 'alleys' ? lineMeta(line) : null, walk = key === 'roads' || key === 'alleys' ? lineWalk(line) : null;
  if (before.length >= 2) repl.push(before); if (after.length >= 2) repl.push(after);
  if (meta) repl.forEach(part => { setLineMeta(part, meta); setLineWalk(part, walk); });
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
  return clusterRoadIntersections(pts, 12).filter(p => roadArmsAt(p[0], p[1], LINE_M.road * 1.4) >= 3);
}
function clusterRoadIntersections(points, radiusM = 12) {
  if (points.length < 2) return points;
  const meanLat = points.reduce((sum, p) => sum + p[0], 0) / points.length, lngScale = mPerDegLng(meanLat), cell = radiusM;
  const parent = points.map((_, i) => i), find = i => { while (parent[i] !== i) { parent[i] = parent[parent[i]]; i = parent[i]; } return i; };
  const union = (a, b) => { const ra = find(a), rb = find(b); if (ra !== rb) parent[rb] = ra; };
  const buckets = new Map(), xy = points.map(p => [p[1] * lngScale, p[0] * MPD_LAT]);
  for (let i = 0; i < points.length; i++) {
    const [x, y] = xy[i], cx = Math.floor(x / cell), cy = Math.floor(y / cell);
    for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) {
      const nearby = buckets.get(`${cx + dx}:${cy + dy}`) || [];
      for (const j of nearby) if (Math.hypot(x - xy[j][0], y - xy[j][1]) <= radiusM) union(i, j);
    }
    const key = `${cx}:${cy}`, list = buckets.get(key) || []; list.push(i); buckets.set(key, list);
  }
  const groups = new Map();
  for (let i = 0; i < points.length; i++) { const root = find(i), group = groups.get(root) || { lat: 0, lng: 0, count: 0 }; group.lat += points[i][0]; group.lng += points[i][1]; group.count++; groups.set(root, group); }
  return [...groups.values()].map(g => [g.lat / g.count, g.lng / g.count]);
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
function crossingAxisDiff(a, b) { const d = Math.abs(((a - b) % Math.PI + Math.PI) % Math.PI); return Math.min(d, Math.PI - d); }
function sameCrossing(a, b, radiusM = 6) { return distMeters(a.lat, a.lng, b.lat, b.lng) <= radiusM && crossingAxisDiff(a.ang, b.ang) < 18 * Math.PI / 180; }
const CROSSWALK_STORED_MAX_M = Math.max(12, LINE_M.road * 2.5);
function manualCrosswalkOnRoad(raw) {
  if (!raw || !Number.isFinite(Number(raw.lat)) || !Number.isFinite(Number(raw.lng))) return null;
  const hit = nearestLinePointForGroups(L.latLng(Number(raw.lat), Number(raw.lng)), ['roads']);
  if (!hit || distMeters(Number(raw.lat), Number(raw.lng), hit.point.lat, hit.point.lng) > CROSSWALK_STORED_MAX_M) return null;
  const a = hit.line[hit.segment], b = hit.line[hit.segment + 1], E = (b[1] - a[1]) * mPerDegLng(hit.point.lat), N = (b[0] - a[0]) * MPD_LAT;
  return { lat: hit.point.lat, lng: hit.point.lng, ang: Math.atan2(N, E), raw };
}
function placeCrosswalk(latlng) {
  const hit = nearestLinePointForGroups(latlng, ['roads']);
  if (!hit || hit.distance > Math.max(12, roadPx() * 2.5)) { flash('Переход можно поставить только на дороге', true); return; }
  const crossing = manualCrosswalkOnRoad({ lat: hit.point.lat, lng: hit.point.lng });
  if (!crossing) { flash('Не удалось привязать переход к дороге', true); return; }
  if (state.crosswalks.map(manualCrosswalkOnRoad).filter(Boolean).some(c => sameCrossing(c, crossing, 5))) { flash('Здесь уже есть переход', true); return; }
  pushUndo(); state.crosswalks.push({ lat: crossing.lat, lng: crossing.lng, ang: crossing.ang }); save(); renderZebras();
}
function renderZebras() {
  zebraLayer.clearLayers();
  const manual = state.crosswalks.map(manualCrosswalkOnRoad).filter(Boolean);
  manual.forEach(drawCrosswalk);
  const drawn = [];
  for (const X of roadIntersections()) for (const ang of roadsAt(X[0], X[1], LINE_M.road * 1.4)) for (const arm of [1, -1]) {
    const ca = Math.cos(ang), sa = Math.sin(ang), center = offset(X[0], X[1], ca * LINE_M.road * .95 * arm, sa * LINE_M.road * .95 * arm);
    if (!roadsAt(center[0], center[1], LINE_M.road * .8).some(d => dirAligned(d, ang))) continue;
    const crossing = { lat: center[0], lng: center[1], ang };
    if (manual.some(c => sameCrossing(c, crossing)) || drawn.some(c => sameCrossing(c, crossing))) continue;
    const legacyKey = `${X[0].toFixed(5)},${X[1].toFixed(5)}@${Math.round(((ang * 180 / Math.PI) % 180 + 180) % 180)}#${arm}`;
    const stableKey = `auto:${center[0].toFixed(4)},${center[1].toFixed(4)}@${Math.round(((ang * 180 / Math.PI) % 180 + 180) % 180)}`;
    if (state.noZebra.includes(legacyKey) || state.noZebra.includes(stableKey)) continue;
    drawn.push(crossing); drawZebraArm(center, ang, stableKey);
  }
}
function drawCrossingStripes(center, roadAng, stripeLength, roadWidth, count) {
  const ca = Math.cos(roadAng), sa = Math.sin(roadAng), perpE = -sa, perpN = ca;
  for (let s = 0; s < count; s++) {
    const off = -roadWidth / 2 + (s + 0.5) * (roadWidth / count), stripeCenter = offset(center[0], center[1], ca * off, sa * off);
    const p1 = offset(stripeCenter[0], stripeCenter[1], perpE * stripeLength / 2, perpN * stripeLength / 2), p2 = offset(stripeCenter[0], stripeCenter[1], -perpE * stripeLength / 2, -perpN * stripeLength / 2);
    L.polyline([p1, p2], { pane: 'pane-cross', color: '#f2f2f2', weight: 3, opacity: .95, interactive: false }).addTo(zebraLayer);
  }
}
function drawCrosswalk(c) {
  const ca = Math.cos(c.ang), sa = Math.sin(c.ang), along = 3.6, across = LINE_M.road * 0.92, perpE = -sa, perpN = ca;
  drawCrossingStripes([c.lat, c.lng], c.ang, along, across, 6);
  const at = (dl, dw) => offset(c.lat, c.lng, dl * ca + dw * perpE, dl * sa + dw * perpN);
  const hl = across / 2 + 1, hw = along / 2 + 1, rect = [at(hl, hw), at(hl, -hw), at(-hl, -hw), at(-hl, hw)];
  const hit = L.polygon(rect, { pane: 'pane-cross', stroke: false, fillOpacity: 0 }).addTo(zebraLayer);
  hit.on('click', e => { if (activeTool !== 'erase') return; L.DomEvent.stop(e); pushUndo(); state.crosswalks = state.crosswalks.filter(x => x !== c.raw); save(); renderZebras(); });
  hit.on('mouseover', () => { if (activeTool !== 'erase') return; clearHover(); hoverHL = L.polygon(rect, { pane: 'pane-edit', color: '#E0245E', weight: 2, fill: false, interactive: false }).addTo(map); });
  hit.on('mouseout', clearHover);
}
function drawZebraArm(center, ang, key) {
  const across = LINE_M.road * 0.82, along = 3.2, ca = Math.cos(ang), sa = Math.sin(ang), perpE = -sa, perpN = ca;
  drawCrossingStripes(center, ang, along, across, 5);
  const at = (dl, dw) => offset(center[0], center[1], dl * ca + dw * perpE, dl * sa + dw * perpN);
  const hl = across / 2 + 1, hw = along / 2 + 1, rect = [at(hl, hw), at(hl, -hw), at(-hl, -hw), at(-hl, hw)];
  const hit = L.polygon(rect, { pane: 'pane-cross', stroke: false, fillOpacity: 0 }).addTo(zebraLayer);
  hit.on('click', e => { if (activeTool !== 'erase') return; L.DomEvent.stop(e); pushUndo(); if (!state.noZebra.includes(key)) state.noZebra.push(key); save(); renderZebras(); });
  hit.on('mouseover', () => { if (activeTool !== 'erase') return; clearHover(); hoverHL = L.polygon(rect, { pane: 'pane-edit', color: '#E0245E', weight: 2, fill: false, interactive: false }).addTo(map); });
  hit.on('mouseout', clearHover);
}
function renderLights() {
  lightLayer.clearLayers();
  state.lights.forEach(l => {
    const m = L.marker([l.lat, l.lng], { pane: 'markerPane', icon: L.divIcon({ className: '', iconSize: [12, 12], iconAnchor: [6, 6], html: '<div class="tl-top"></div>' }) }).addTo(lightLayer);
    m.on('click', e => { if (activeTool !== 'erase') return; L.DomEvent.stop(e); pushUndo(); state.lights = state.lights.filter(x => x !== l); save(); renderLights(); });
  });
}

function transportIcon(kind, text) {
  return L.divIcon({ className: '', iconSize: [0, 0], iconAnchor: [0, 0], html: `<div class="transport-marker ${kind}">${text}</div>` });
}
function nearestLinePointForGroups(latlng, groups) {
  const p = map.latLngToLayerPoint(latlng); let best = null;
  for (const key of groups) for (const line of state[key] || []) {
    for (let i = 1; i < line.length; i++) {
      const a = map.latLngToLayerPoint(L.latLng(line[i - 1][0], line[i - 1][1])), b = map.latLngToLayerPoint(L.latLng(line[i][0], line[i][1])), q = projSeg(p, a, b), d = p.distanceTo(q);
      if (!best || d < best.distance) best = { key, line, segment: i - 1, point: map.layerPointToLatLng(q), distance: d };
    }
  }
  return best;
}
function nearestNetworkEndpoint(latlng, radius = 28) {
  const p = map.latLngToLayerPoint(latlng); let best = null;
  for (const key of ['roads', 'alleys', 'rails', 'paths']) for (const line of state[key] || []) {
    if (line.length < 2) continue;
    for (const atEnd of [false, true]) {
      const pt = atEnd ? line[line.length - 1] : line[0], q = map.latLngToLayerPoint(L.latLng(pt[0], pt[1])), d = p.distanceTo(q);
      if (d <= radius && (!best || d < best.distance)) best = { key, line, atEnd, point: [pt[0], pt[1]], distance: d };
    }
  }
  return best;
}
function lineEndpointExit(line, atEnd, mode) {
  const p = atEnd ? line[line.length - 1] : line[0];
  return state.exits.find(x => Array.isArray(x.modes) && x.modes.includes(mode) && distMeters(x.lat, x.lng, p[0], p[1]) <= 8) || null;
}
function nearestRailPointForStation(station) {
  let best = null;
  for (const line of state.rails || []) {
    if (!line || line.length < 2) continue;
    for (let i = 1; i < line.length; i++) {
      const point = projOnSegLL([station.lat, station.lng], line[i - 1], line[i]), distance = distMeters(station.lat, station.lng, point[0], point[1]);
      if (!best || (roadKey(line) === station.railKey ? distance - 1000 : distance) < best.rank) best = { line, segment: i - 1, point, distance, rank: roadKey(line) === station.railKey ? distance - 1000 : distance };
    }
  }
  return best;
}
const STATION_PLATFORM_LEN = 150, STATION_PLATFORM_W = 5.5, STATION_RAIL_GAP = 1.2, STATION_BUILD_HALF = 5;   // станция под 8-9 вагонов
function stationRailRefByKey(key, segment, t) {          // привязка станции к линии по сохранённому ключу
  if (!key) return null;
  const line = state.rails.find(l => roadKey(l) === key);
  if (!line || line.length < 2) return null;
  const seg = Math.max(0, Math.min(line.length - 2, Number.isInteger(segment) ? segment : 0));
  const tt = Math.max(0, Math.min(1, Number.isFinite(Number(t)) ? Number(t) : 0));
  return { line, seg, t: tt, point: lerpPos(line, seg, tt) };
}
function stationRailRef2(station) { return stationRailRefByKey(station.railKey2, station.railSegment2, station.railT2); }
function stationRailRef(station) {                       // путь станции + позиция (seg,t): ищем по railKey, иначе ближайший рельс
  const direct = stationRailRefByKey(station.railKey, station.railSegment, station.railT);
  if (direct) return direct;
  const hit = nearestRailPointForStation(station);
  if (!hit || !hit.line || !lineDExists(hit.line)) return null;
  const len = distMeters(hit.line[hit.segment][0], hit.line[hit.segment][1], hit.line[hit.segment + 1][0], hit.line[hit.segment + 1][1]) || 1;
  return { line: hit.line, seg: hit.segment, t: Math.max(0, Math.min(1, distMeters(hit.line[hit.segment][0], hit.line[hit.segment][1], hit.point[0], hit.point[1]) / len)), point: hit.point };
}
function lineDExists(line) { return line && line.length >= 2 && line[0] && line[1] && line[0][0] != null && line[1][0] != null; }
function tangentAt(line, i) {                            // единичный касательный вектор (east,north) в сегменте line[i]→line[i+1]
  const a = line[i], b = line[i + 1], E = (b[1] - a[1]) * mPerDegLng(a[0]), N = (b[0] - a[0]) * MPD_LAT, len = Math.hypot(E, N) || 1;
  return { e: E / len, n: N / len };
}
function stationSideOfPoint(ref, clickLatLng) {         // сторона курсора относительно хода пути: 1 слева, -1 справа
  const tan = tangentAt(ref.line, ref.seg), p = ref.point;
  const ce = (clickLatLng.lng - p[1]) * mPerDegLng(p[0]), cn = (clickLatLng.lat - p[0]) * MPD_LAT;
  const cross = tan.e * cn - tan.n * ce;                 // положительный — левее хода
  return cross >= 0 ? 1 : -1;
}
function stationPlatformShape(ref, side, halfLen = STATION_PLATFORM_LEN / 2, width = STATION_PLATFORM_W, innerOffset = STATION_RAIL_GAP) {
  // лента платформы (полигон), повторяющая изгибы рельса вокруг позиции станции, со смещением на сторону
  const cum = [0]; for (let i = 1; i < ref.line.length; i++) cum.push(cum[i - 1] + distMeters(ref.line[i - 1][0], ref.line[i - 1][1], ref.line[i][0], ref.line[i][1]));
  let base = cum[ref.seg] + ref.t * distMeters(ref.line[ref.seg][0], ref.line[ref.seg][1], ref.line[ref.seg + 1][0], ref.line[ref.seg + 1][1]);
  const total = cum[cum.length - 1] || 1, d0 = Math.max(0, base - halfLen), d1 = Math.min(total, base + halfLen);
  const inner = [], outer = [], gap = innerOffset, gapFar = innerOffset + width;   // ближний и дальний край от пути — одинаково для обеих сторон
  for (let d = d0; d <= d1 + 1e-6; d += 2.5) {
    const dd = Math.min(d, d1), at = linePointAtDistance(ref.line, dd);
    const p = lerpPos(ref.line, at[2], Math.max(0, Math.min(1, (dd - cum[at[2]]) / (distMeters(ref.line[at[2]][0], ref.line[at[2]][1], ref.line[at[2] + 1][0], ref.line[at[2] + 1][1]) || 1))));
    const tan = tangentAt(ref.line, at[2]);
    inner.push(offset(p[0], p[1], -tan.n * gap * side, tan.e * gap * side));
    outer.push(offset(p[0], p[1], -tan.n * gapFar * side, tan.e * gapFar * side));
  }
  if (d1 - d0 < 1) { const p = ref.point, tan = tangentAt(ref.line, ref.seg); inner.push(offset(p[0], p[1], -tan.n * gap * side, tan.e * gap * side)); outer.push(offset(p[0], p[1], -tan.n * gapFar * side, tan.e * gapFar * side)); }
  return inner.concat(outer.slice().reverse());
}
function stationGeometry(station) {
  const ref = stationRailRef(station);
  const side = station.side == null ? 1 : station.side;
  let point, e, n, angle, platformPoly, mid, platMid;
  let platformSide = side, platformInner = STATION_RAIL_GAP, platformWidth = STATION_PLATFORM_W, dual = false, dualDir = 0;
  if (ref) {
    point = ref.point;
    const tan = tangentAt(ref.line, ref.seg); e = tan.e; n = tan.n; angle = Math.atan2(n, e) * 180 / Math.PI;
    const ref2 = stationRailRef2(station);
    if (ref2) {                                          // вторая линия по другую сторону: платформа островом между путями
      const de = (ref2.point[1] - point[1]) * mPerDegLng(point[0]), dn = (ref2.point[0] - point[0]) * MPD_LAT;
      const signed = de * (-n) + dn * e, gap = Math.abs(signed);   // >0 — вторая линия левее хода
      if (gap > STATION_RAIL_GAP * 2 + 1 && gap <= 40) {
        dual = true; dualDir = signed >= 0 ? 1 : -1;
        platformWidth = Math.max(2.4, Math.min(12, gap - STATION_RAIL_GAP * 2));
        platformInner = Math.max(STATION_RAIL_GAP, (gap - platformWidth) / 2);
        platformSide = dualDir;
      }
    }
    platformPoly = stationPlatformShape(ref, platformSide, STATION_PLATFORM_LEN / 2, platformWidth, platformInner);
    const midM = platformInner + platformWidth / 2;
    platMid = offset(point[0], point[1], -n * midM * platformSide, e * midM * platformSide);
    if (dual) {                                          // здание снаружи путей, на стороне клика
      const bM = STATION_RAIL_GAP + STATION_BUILD_HALF + 1.5;
      mid = offset(point[0], point[1], -n * bM * side, e * bM * side);
    } else {
      const idx = Math.floor(platformPoly.length / 2), midp = platformPoly[idx];   // середина дальнего края платформы (side inf)
      const midNear = platformPoly[idx + 1] || platformPoly[idx], dde = (midNear[0] - midp[0]) * MPD_LAT / (distMeters(midp[0], midp[1], midNear[0], midNear[1]) || 1), ddn = (midNear[1] - midp[1]) * mPerDegLng(midp[0]) / (distMeters(midp[0], midp[1], midNear[0], midNear[1]) || 1);
      mid = offset(midp[0], midp[1], ddn * (side > 0 ? -1 : 1) * (STATION_BUILD_HALF + 1), -dde * (side > 0 ? -1 : 1) * (STATION_BUILD_HALF + 1));
    }
  } else {
    point = [station.lat, station.lng]; e = Math.cos((Number(station.rot) || 0) * Math.PI / 180); n = Math.sin((Number(station.rot) || 0) * Math.PI / 180);
    angle = Number(station.rot) || 0;
    const half = STATION_PLATFORM_LEN / 2, gap = STATION_RAIL_GAP + STATION_PLATFORM_W;
    platformPoly = [ [e * half + n * gap, n * half - e * gap], [-e * half + n * gap, n * half - e * gap], [-e * half + n * gap, -n * half - e * gap], [e * half + n * gap, -n * half - e * gap] ].map(d => offset(point[0], point[1], d[0], d[1]));
    mid = offset(point[0], point[1], n * (STATION_RAIL_GAP + STATION_PLATFORM_W + STATION_BUILD_HALF + 1.5), -e * (STATION_RAIL_GAP + STATION_PLATFORM_W + STATION_BUILD_HALF + 1.5));
    const midM = STATION_RAIL_GAP + STATION_PLATFORM_W / 2;
    platMid = offset(point[0], point[1], -n * midM * platformSide, e * midM * platformSide);
  }
  const platform = { lat: point[0], lng: point[1], w: STATION_PLATFORM_LEN, h: platformWidth, rot: angle }, building = { lat: mid[0], lng: mid[1], w: 26, h: STATION_BUILD_HALF * 2, rot: angle };
  return { point, platform, building, e, n, angle, platformPoly: platformPoly.map(p => [p[0], p[1]]), platformSide, platformInner, platformWidth, platformMid: platMid, dual, dualDir };
}
function stationEntryPoint(station) { const building = stationGeometry(station).building; return [building.lat, building.lng]; }
function stationSnapLines() { return (state.stations || []).map(station => [stationEntryPoint(station)]); }
function stationAtEntry(point, tolerance = .75) { return (state.stations || []).find(station => { const entry = stationEntryPoint(station); return distMeters(point.lat, point.lng, entry[0], entry[1]) <= tolerance; }) || null; }
function pedestrianBaseLines() {
  const lines = [];
  state.paths.forEach(line => { if (line.length >= 2 && roadLen(line) > 1.2) lines.push(line); });   // тропинки короткие, но нужные
  state.alleys.forEach(line => {                                    // проезд: идём по краям, а не по центру
    const walk = state.roadWalk[roadKey(line)] || 'both', offsetM = LINE_M.alley / 2 + 0.5;
    const sides = walk === 'left' ? [offsetM] : walk === 'right' ? [-offsetM] : [offsetM, -offsetM];
    sides.forEach(side => { const edge = offsetLine(line, side); if (edge.length >= 2 && roadLen(edge) > 1.2) lines.push(edge); });
  });
  state.roads.forEach(line => {
    const walk = state.roadWalk[roadKey(line)] || 'both', offsetM = lineWidthM(line) / 2 + 1;
    const sides = walk === 'both' ? [offsetM, -offsetM] : walk === 'left' ? [offsetM] : walk === 'right' ? [-offsetM] : [];
    sides.forEach(side => { const sidewalk = offsetLine(line, side); if (sidewalk.length >= 2 && roadLen(sidewalk) > 1.2) lines.push(sidewalk); });
  });
  return lines;
}
const STATION_ACCESS_SNAP_M = 8;
function stationAccessInfo(station, baseLines = pedestrianBaseLines()) {
  if (!baseLines.length) return null;
  const geometry = stationGeometry(station), entry = [geometry.building.lat, geometry.building.lng]; let best = null;
  for (const line of baseLines) for (let segment = 1; segment < line.length; segment++) {
    const point = projOnSegLL(entry, line[segment - 1], line[segment]), distance = distMeters(entry[0], entry[1], point[0], point[1]);
    if (!best || distance < best.distance) {
      const length = distMeters(line[segment - 1][0], line[segment - 1][1], line[segment][0], line[segment][1]) || 1;
      best = { line, segment: segment - 1, t: Math.max(0, Math.min(1, distMeters(line[segment - 1][0], line[segment - 1][1], point[0], point[1]) / length)), point, distance };
    }
  }
  if (!best || best.distance > STATION_ACCESS_SNAP_M) return null;
  return { stationPoint: entry, networkPoint: best.point, distance: best.distance, networkLine: best.line, segment: best.segment, t: best.t };
}
function connectDrawToStation(station, event) {
  if (!draw.active || !isStationAccessDrawMode(draw.mode)) return false;
  L.DomEvent.stop(event);
  const endpoint = L.latLng(...stationEntryPoint(station)), lastIndex = draw.points.length - 1;
  if (lastIndex >= 0 && map.distance(draw.points[lastIndex], endpoint) < 1) {
    draw.points[lastIndex] = endpoint;
    const handle = draw.handles[lastIndex];
    if (handle) { handle.setLatLng(endpoint); handle.setIcon(L.divIcon({ className: '', html: '<div class="vertex-dot snapped station-endpoint"></div>', iconSize: [12, 12], iconAnchor: [6, 6] })); }
    draw.stationPoints = draw.stationPoints.filter(x => x.index !== lastIndex);
    draw.stationPoints.push({ index: lastIndex, point: [endpoint.lat, endpoint.lng] });
  } else {
    addDrawVertex(endpoint, true, station);
  }
  draw.preview.setLatLngs(draw.points); updateDrawHint();
  flash('Зелёная точка привязана к станции; продолжи линию или нажми «Готово»');
  return true;
}
function refreshStationAccessInRunningSim(addedLine, drawMode) {
  if (!sim.on) return;
  const additions = [];
  if (drawMode === 'path' || baseLineMode(drawMode) === 'alley') additions.push(addedLine);
  else if (isDriveDrawMode(drawMode) && baseLineMode(drawMode) === 'road') {
    const walk = lineWalk(addedLine), offsetM = lineWidthM(addedLine) / 2 + 1;
    const sides = walk === 'both' ? [offsetM, -offsetM] : walk === 'left' ? [offsetM] : walk === 'right' ? [-offsetM] : [];
    sides.forEach(side => { const sidewalk = offsetLine(addedLine, side); if (sidewalk.length >= 2 && roadLen(sidewalk) > 4) additions.push(sidewalk); });
  }
  const signature = line => line.map(point => `${Number(point[0]).toFixed(6)},${Number(point[1]).toFixed(6)}`).join(';');
  const known = new Set(sim.pedLines.map(signature));
  const newLines = additions.filter(line => line && line.length >= 2 && roadLen(line) > 4 && !known.has(signature(line)));
  newLines.forEach(line => sim.pedLines.push(line));
  sim.pedNet = pedNetBuild(sim.pedLines);                      // новый участок — пересобрать граф маршрутов
  sim.stationAccess = new Map(); sim.transitStations = [];
  for (const station of state.stations) {
    const access = stationAccessInfo(station, sim.pedLines);
    if (access) { sim.stationAccess.set(station, access); sim.transitStations.push(station); }
  }
  for (const line of newLines) {
    const count = Math.min(25, Math.max(1, Math.round(roadLen(line) / 40)));
    for (let i = 0; i < count && sim.peds.length < 500; i++) {
      const pedestrian = prepareCitizenEntry(makeCitizen(line)); assignDest(pedestrian); sim.peds.push(pedestrian);
    }
  }
}
let stationAssign = null;                              // станция, ожидающая клика по второму пути
function assignStationSecondRail(station, latlng) {    // ручное присвоение второго ЖД-пути станции
  const hit = nearestLinePointForGroups(latlng, ['rails']);
  if (!hit || hit.distance > Math.max(22, mToPx(LINE_M.rail) * 2.4)) { flash('Кликни по второму ЖД-пути', true); return false; }
  const key = roadKey(hit.line);
  if (key === station.railKey) {                       // клик по своему пути — снять второй
    if (!station.railKey2) { flash('Это путь самой станции; кликни по соседнему пути', true); return false; }
    pushUndo(); station.railKey2 = null; station.railSegment2 = null; station.railT2 = null;
    save(); flash('Второй путь снят со станции'); return true;
  }
  const point = [hit.point.lat, hit.point.lng], gap = distMeters(station.lat, station.lng, point[0], point[1]);
  if (gap > 26) { flash('Второй путь слишком далеко (до 26 м)', true); return false; }
  if (gap <= STATION_RAIL_GAP * 2 + 1) { flash('Пути почти совпадают — выбери соседний путь', true); return false; }
  const a = hit.line[hit.segment], b = hit.line[hit.segment + 1], len = distMeters(a[0], a[1], b[0], b[1]) || 1;
  const ref1 = stationRailRef(station);
  pushUndo();
  station.railKey2 = key; station.railSegment2 = hit.segment;
  station.railT2 = Math.max(0, Math.min(1, distMeters(a[0], a[1], point[0], point[1]) / len));
  if (ref1) station.side = -stationSideOfPoint(ref1, { lat: point[0], lng: point[1] });   // вокзал снаружи от обоих путей
  save(); flash('Второй путь присвоен станции'); return true;
}
function placeStation(latlng) {
  const hit = nearestLinePointForGroups(latlng, ['rails']);
  if (!hit || hit.distance > Math.max(22, mToPx(LINE_M.rail) * 2.4)) { flash('Станция ставится на железнодорожный путь', true); return; }
  if (state.stations.some(s => distMeters(s.lat, s.lng, hit.point.lat, hit.point.lng) < 18)) { flash('Здесь уже есть станция', true); return; }
  const a = hit.line[hit.segment], b = hit.line[hit.segment + 1], E = (b[1] - a[1]) * mPerDegLng(a[0]), N = (b[0] - a[0]) * MPD_LAT, segmentLength = Math.hypot(E, N) || 1, railT = Math.max(0, Math.min(1, distMeters(a[0], a[1], hit.point.lat, hit.point.lng) / segmentLength)), angle = Math.atan2(N, E) * 180 / Math.PI;
  const ref = { line: hit.line, seg: hit.segment, point: [hit.point.lat, hit.point.lng] };
  let side = stationSideOfPoint(ref, latlng);
  const station = { lat: hit.point.lat, lng: hit.point.lng, name: 'Станция ' + (state.stations.length + 1), railKey: roadKey(hit.line), railSegment: hit.segment, railT, rot: angle, w: 13, h: 8, side };
  pushUndo(); state.stations.push(station); save(); renderTransport(); updateStats();
  flash(stationAccessInfo(station) ? 'Станция подключена к пешеходной сети' : 'Станция построена; клик по станции инструментом «Станция» присвоит второй путь');
}
function placeParking(latlng) {
  const hit = nearestLinePointForGroups(latlng, ['roads', 'alleys']);
  if (!hit || hit.distance > Math.max(24, mToPx(LINE_M.road) * 2.2)) { flash('Парковку ставь рядом с дорогой', true); return; }
  const a = hit.line[hit.segment], b = hit.line[hit.segment + 1], E = (b[1] - a[1]) * mPerDegLng(a[0]), N = (b[0] - a[0]) * MPD_LAT, len = Math.hypot(E, N) || 1;
  const gap = lineWidthM(hit.line) / 2 + 6, center = offset(hit.point.lat, hit.point.lng, -N / len * gap, E / len * gap), rot = Math.atan2(N, E) * 180 / Math.PI;
  const item = { lat: center[0], lng: center[1], w: 22, h: 9, rot, capacity: 6 };
  if (state.parking.some(p => distMeters(p.lat, p.lng, item.lat, item.lng) < 12)) { flash('Здесь уже есть парковка', true); return; }
  pushUndo(); state.parking.push(item); save(); renderTransport(); updateStats(); flash('Парковка добавлена');
}
function placeExit(latlng) {
  const hit = nearestNetworkEndpoint(latlng);
  if (!hit) { flash('Выход ставится только на конце дороги, тропы или ЖД', true); return; }
  const modes = new Set();
  for (const key of ['roads', 'alleys', 'rails', 'paths']) for (const line of state[key] || []) {
    if (line.some(p => distMeters(p[0], p[1], hit.point[0], hit.point[1]) < 8)) {
      if (key === 'rails') modes.add('rail'); else { modes.add('road'); modes.add('walk'); }
    }
  }
  if (state.exits.some(x => distMeters(x.lat, x.lng, hit.point[0], hit.point[1]) < 8)) { flash('Здесь уже есть выход', true); return; }
  pushUndo(); state.exits.push({ lat: hit.point[0], lng: hit.point[1], modes: [...modes], name: 'Выход ' + (state.exits.length + 1) }); save(); renderTransport(); updateStats(); flash('Внешний вход/выход подключён');
}
function renderTransport() {
  if (!transportLayer) return;
  transportLayer.clearLayers();
  state.parking.forEach(p => {
    const poly = L.polygon(rectCorners(p), { pane: 'pane-builds', className: 'parking-field', color: '#c4cbd0', weight: 1.5, fillColor: '#4b545b', fillOpacity: .88 }).addTo(transportLayer);
    const ca = Math.cos((p.rot || 0) * Math.PI / 180), sa = Math.sin((p.rot || 0) * Math.PI / 180), slots = Math.max(2, Math.min(8, p.capacity || 6));
    for (let i = 1; i < slots; i++) {
      const dx = -p.w / 2 + p.w * i / slots, a = offset(p.lat, p.lng, dx * ca - p.h / 2 * sa, dx * sa + p.h / 2 * ca), b = offset(p.lat, p.lng, dx * ca + p.h / 2 * sa, dx * sa - p.h / 2 * ca);
      L.polyline([a, b], { pane: 'pane-edit', color: 'rgba(255,255,255,.72)', weight: 1, interactive: false }).addTo(transportLayer);
    }
    poly.on('click', e => { if (activeTool !== 'erase') return; L.DomEvent.stop(e); pushUndo(); state.parking = state.parking.filter(x => x !== p); save(); renderTransport(); updateStats(); });
  });
  state.stations.forEach(s => {
    const g = stationGeometry(s), access = stationAccessInfo(s), assigning = stationAssign === s;
    const connectedClass = access ? ' connected' : '';
    const accent = assigning ? '#4aa3ff' : access ? '#42dc83' : null;
    const platform = L.polygon(g.platformPoly, { pane: 'pane-builds', className: `station-platform${connectedClass}${assigning ? ' assigning' : ''}`, color: accent || '#e4c875', weight: assigning ? 2.6 : 1.4, fillColor: assigning ? '#2f5d8d' : access ? '#477758' : '#8d7651', fillOpacity: .84 }).addTo(transportLayer);
    const building = L.polygon(rectCorners(g.building), { pane: 'pane-builds', className: `station-building${connectedClass}${assigning ? ' assigning' : ''}`, color: accent || '#ffd975', weight: assigning ? 2.6 : 1.4, fillColor: assigning ? '#2f5d8d' : access ? '#315b48' : '#5a4352', fillOpacity: .96 }).addTo(transportLayer);
    const stopMark = (point, e, n) => {               // поперечная линия остановки поезда на пути
      const a = offset(point[0], point[1], -n * 3, e * 3), b = offset(point[0], point[1], n * 3, -e * 3);
      L.polyline([a, b], { pane: 'pane-edit', color: '#f7df8c', weight: Math.max(1, railPx() * .38), opacity: .95, interactive: false, lineCap: 'round' }).addTo(transportLayer);
    };
    stopMark(g.point, g.e, g.n);
    if (g.dual) {                                      // двусторонняя: маркер остановки и на втором пути
      const ref2 = stationRailRef2(s);
      if (ref2) { const tan2 = tangentAt(ref2.line, ref2.seg); stopMark(ref2.point, tan2.e, tan2.n); }
    }
    const m = L.marker([g.building.lat, g.building.lng], { pane: 'markerPane', icon: transportIcon(access ? 'station connected' : 'station', 'ЖД') }).addTo(transportLayer);
    m.bindTooltip((s.name || 'Станция') + (access ? ` · вход подключён · пеший подход ${fmtLen(access.distance)}` : ' · нет пешеходной сети'), { direction: 'top', offset: [0, -8] });
    const stationClick = e => {
      if (activeTool === 'erase') { L.DomEvent.stop(e); pushUndo(); state.stations = state.stations.filter(x => x !== s); save(); renderTransport(); updateStats(); return; }
      if (activeTool === 'station') {                  // клик по станции — режим присваивания второго пути
        L.DomEvent.stop(e);
        stationAssign = stationAssign === s ? null : s;
        renderTransport();
        flash(stationAssign ? `${s.name}: клик по второму ЖД-пути присвоит его (повторный клик по станции — отмена)` : 'Присваивание второго пути отменено');
        return;
      }
      connectDrawToStation(s, e);
    };
    platform.on('click', stationClick); building.on('click', stationClick); m.on('click', stationClick);
  });
  state.exits.forEach(x => {
    const m = L.marker([x.lat, x.lng], { pane: 'markerPane', icon: transportIcon('exit', 'ВЫХОД') }).addTo(transportLayer);
    m.bindTooltip((x.name || 'Выход') + ' · ' + (x.modes || []).join(', '), { direction: 'top', offset: [0, -8] });
    m.on('click', e => { if (activeTool !== 'erase') return; L.DomEvent.stop(e); pushUndo(); state.exits = state.exits.filter(v => v !== x); save(); renderTransport(); updateStats(); });
  });
}

function renderAll() {
  if (repairNetworkConnections(true)) save();
  renderTerritory(); renderDistricts(); renderRoads(); renderAlleys(); renderPaths(); renderRails(); renderCrossings(); renderZebras(); renderBuildings(); renderLights(); renderTransport(); renderCountryLabels(); updateStats(); document.getElementById('state-name').value = state.name; paintFlag(); updateUndoBtn();
}

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
  const n = state.buildings.length + state.roads.length + state.rails.length + state.paths.length + state.alleys.length + state.stations.length + state.parking.length + state.exits.length;
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
function importFile(file) { const r = new FileReader(); r.onload = () => { try { state = migrate(Object.assign(freshState(), JSON.parse(r.result))); undoStack = []; ensureWalkways(false); save(); deselect(); document.getElementById('state-name').value = state.name; buildPalette(); renderAll(); locate(); flash('Государство загружено'); } catch (e) { flash('Не удалось прочитать файл', true); } }; r.readAsText(file); }
let flashTimer = null;
function flash(msg, bad) { const t = document.getElementById('toast'); t.textContent = msg; t.style.color = bad ? '#E0245E' : ''; t.classList.remove('hidden'); clearTimeout(flashTimer); flashTimer = setTimeout(() => t.classList.add('hidden'), 1800); }

/* ════════════════ TRAFFIC SIM (cars + people) ════════════════ */
const CAR_COLORS = ['#e74c3c', '#3498db', '#ecf0f1', '#2c3e50', '#f1c40f', '#16a085', '#e67e22', '#8e44ad', '#bdc3c7'];
const TRUCK_COLORS = ['#8c6f55', '#627d98', '#b24c3b', '#a5a5a5', '#3d5a80', '#6b7280'];
const VEHICLE_TYPES = {
  car: { length: 3.8, width: 1.7, minSpeed: 8, maxSpeed: 16, accel: 9, brake: 28, maxLatAccel: 7.5 },
  truck: { length: 8.6, width: 2.45, minSpeed: 5.5, maxSpeed: 11, accel: 5.5, brake: 21, maxLatAccel: 4.2, cabLength: 2.4, trailerLength: 6.2, trailerWheelbase: 5.1 }
};
// Поезд: 8 вагонов, каждый — звено цепи со своей геометрией. Локомотив ведёт (нос едет
// по ЖД-пути + дуги), прицепные ставятся на фиксированную дистанцию позади по направлению
// тела предыдущего — сцепки не растягиваются и не налезают, поезд плавно изгибается на поворотах.
const TRAIN_WAGONS = 8, TRAIN_WAGON_LEN = 16, TRAIN_WAGON_GAP = 0.8, TRAIN_COUPLING = TRAIN_WAGON_LEN + TRAIN_WAGON_GAP, TRAIN_WIDTH = 2.4;
const TRAIN_LOCO_COLORS = ['#b0242a', '#2c5aa0', '#3a7d44', '#7a3a9e'];
const PED_COLORS = ['#ffd24a', '#5ad06a', '#ff8a5c', '#5cc8ff', '#e8e8e8', '#d98cff'];
const sim = { on: false, cars: [], parkedCars: [], parkingLots: [], peds: [], trains: [], driveLines: [], railLines: [], pedLines: [], raf: 0, last: 0, t: 0, selected: null, follow: false, _panelT: 0, _trafficT: 0, _trafficLanes: null, _junctionTraffic: null, _junctionRequests: null, workload: new Map() };
// Экономика: те же правила, что на сервере (server.py), для локальной оценки
const RESIDENTS_PER_HOUSE = 4, JOBS_PER_SHOP = 12;
const TAX_EMPLOYED_HR = 10.0, TAX_UNEMPLOYED_HR = 2.5;
const UPKEEP_ROAD_KM_HR = 1.0, UPKEEP_STATION_HR = 3.0, UPKEEP_PARKING_HR = 1.0, UPKEEP_LIGHT_HR = 0.3, UPKEEP_CROSSWALK_HR = 0.1;
let simCanvas = null, simCtx = null;
let _vehicleId = 0;
let _trainId = 0;
function resizeSim() { if (!simCanvas) return; const dpr = window.devicePixelRatio || 1; simCanvas.width = innerWidth * dpr; simCanvas.height = innerHeight * dpr; simCanvas.style.width = innerWidth + 'px'; simCanvas.style.height = innerHeight + 'px'; }

function roadLen(r) { let d = 0; for (let i = 1; i < r.length; i++) d += distMeters(r[i - 1][0], r[i - 1][1], r[i][0], r[i][1]); return d; }
function driveWidth(line) { return lineWidthM(line); }
function laneOffset(line) { return Math.max(.75, Math.min(1.7, driveWidth(line) * .25)); }
// Замкнутая линия: конец совпадает с началом (кольцо). Машина должна ехать
// по кругу дальше, а не умирать на «шве» из-за запрета разворота.
function lineIsClosed(line) {
  if (!line || line.length < 4) return false;
  const a = line[0], b = line[line.length - 1];
  return distMeters(a[0], a[1], b[0], b[1]) <= Math.max(3, laneOffset(line) * 2);
}
// Примыкания к кольцу: другие дороги упираются в него где угодно — в том числе
// в середину сегмента. Кэш на массив линии, сбрасывается при перестройке сети.
const _ringExitCache = new WeakMap();
function ringExitAnchors(line) {
  if (_ringExitCache.has(line)) return _ringExitCache.get(line);
  const out = [], tol = Math.max(6, LINE_M.road * .9), cum = roadCum(line), L = cum[cum.length - 1] || 1;
  for (const other of sim.driveLines) {
    if (other === line || other.length < 2) continue;
    for (const end of [other[0], other[other.length - 1]]) {
      let best = null;
      for (let i = 1; i < line.length; i++) {
        const hit = projOnSegLL(end, line[i - 1], line[i]);
        const d = distMeters(end[0], end[1], hit[0], hit[1]);
        if (!best || d < best.d) best = { d, i, hit };
      }
      if (!best || best.d > tol) continue;
      out.push({ line: other, point: best.hit, progress: cum[best.i - 1] + distMeters(line[best.i - 1][0], line[best.i - 1][1], best.hit[0], best.hit[1]) });
    }
  }
  out.sort((a, b) => a.progress - b.progress);
  const data = { anchors: out, length: L };
  _ringExitCache.set(line, data);
  return data;
}
// Машина на кольце решает, съезжать ли на ближайшее примыкание.
function ringExitTurn(c) {
  const line = c.line, data = ringExitAnchors(line);
  if (!data.anchors.length) return null;
  const p = lineProgress(line, c.seg, c.t, true), lead = turnLead(c);
  if (c._ringExitAt != null && (p - c._ringExitAt + data.length) % data.length > 30) c._ringExitAt = null;   // примыкание осталось позади
  let next = null, bestD = Infinity;
  for (const a of data.anchors) {
    const d = (a.progress - p + data.length) % data.length;
    if (d > .2 && d < lead + 3 && d < bestD) { bestD = d; next = a; }
  }
  if (!next || c._ringExitAt === next.progress) return null;
  c._ringExitAt = next.progress;
  if (Math.random() > .6) return null;
  const options = (junctionOptions(c, next.point, true) || []).filter(o => o.line === next.line);
  const pick = options.length ? randomRouteOption(c, options, line) : null;
  if (!pick) return null;
  const reach = lineDistanceToEnd(pick.line, pick.seg, pick.t, pick.fwd), exitLead = Math.min(turnLead(c), Math.max(1.2, reach * .42));
  const turn = buildVehicleTurn(c, pick, next.point, lineStateAfter(pick.line, pick.seg, pick.t, pick.fwd, exitLead), exitLead, true);
  if (!turn || vehicleTurnBlocked(c, turn)) return null;
  return turn;
}
function trafficLaneKey(line, fwd, lane) { return lineMeta(line).oneWay ? `${fwd ? 'true' : 'false'}:${lane === 1 ? 1 : 0}` : (fwd ? 'true' : 'false'); }
function segmentVector(line, seg, fwd) {
  const a = line[seg], b = line[seg + 1];
  if (!a || !b) return { e: 0, n: 0, len: 0 };
  let e = (b[1] - a[1]) * mPerDegLng(a[0]), n = (b[0] - a[0]) * MPD_LAT;
  if (!fwd) { e = -e; n = -n; }
  const len = Math.hypot(e, n) || 1;
  return { e: e / len, n: n / len, len: len };
}
function lineLanePoint(line, seg, t, fwd, lane = 0) {
  const a = line[seg], b = line[seg + 1];
  if (!a || !b) return null;
  const center = lerpPos(line, seg, t), raw = segmentVector(line, seg, true);
  const side = lineMeta(line).oneWay ? (lane === 1 ? -1 : 1) : (fwd ? 1 : -1), gap = laneOffset(line) * side;
  // Right-hand traffic: offset from the stored line direction, then reverse
  // the offset for vehicles travelling against that stored direction.
  return offset(center[0], center[1], raw.n * gap, -raw.e * gap);
}
function lineStateAfter(line, seg, t, fwd, distance) {
  let s = Math.max(0, Math.min(line.length - 2, seg)), u = Math.max(0, Math.min(1, t));
  let left = Math.max(0, distance), guard = 0;
  while (left > 1e-5 && guard++ < line.length + 4) {
    const raw = segmentVector(line, s, true), available = fwd ? (1 - u) * raw.len : u * raw.len;
    if (left <= available + 1e-5) {
      u += (fwd ? 1 : -1) * left / raw.len;
      return { line, seg: s, t: Math.max(0, Math.min(1, u)), fwd };
    }
    left -= Math.max(0, available);
    if (fwd) { if (s >= line.length - 2) { u = 1; break; } s++; u = 0; }
    else { if (s <= 0) { u = 0; break; } s--; u = 1; }
  }
  return { line, seg: s, t: Math.max(0, Math.min(1, u)), fwd };
}
function angleDelta(a, b) { return Math.atan2(Math.sin(a - b), Math.cos(a - b)); }
function quadraticPoint(a, control, b, t) {
  const u = 1 - t;
  return [u * u * a[0] + 2 * u * t * control[0] + t * t * b[0], u * u * a[1] + 2 * u * t * control[1] + t * t * b[1]];
}
function turnSamples(a, control, b) {
  const samples = [], cum = [0], count = 18;
  for (let i = 0; i <= count; i++) {
    const p = quadraticPoint(a, control, b, i / count); samples.push(p);
    if (i) cum.push(cum[i - 1] + distMeters(samples[i - 1][0], samples[i - 1][1], p[0], p[1]));
  }
  return { samples, cum, length: cum[cum.length - 1] || 0.01 };
}
function turnPose(c) {
  const tr = c.turn; if (!tr || !tr.samples.length) return null;
  let i = 1; while (i < tr.cum.length - 1 && tr.cum[i] < tr.s) i++;
  const a = tr.samples[i - 1], b = tr.samples[i], span = tr.cum[i] - tr.cum[i - 1] || 1;
  const f = Math.max(0, Math.min(1, (tr.s - tr.cum[i - 1]) / span)), pos = [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f];
  const p0 = tr.samples[Math.max(0, i - 2)], p1 = tr.samples[Math.min(tr.samples.length - 1, i + 1)];
  const e = (p1[1] - p0[1]) * mPerDegLng(pos[0]), n = (p1[0] - p0[0]) * MPD_LAT;
  return { pos, angle: Math.atan2(n, e) };
}
// Deliberately linear on each segment. The old Catmull-Rom curve could
// overshoot a short/sharp segment and put the sprite outside the road.
function smoothLinePoint(line, seg, t) { return lerpPos(line, seg, t); }
function smoothCarPose(c) {
  if (c.turn) return turnPose(c);
  const line = c.line, p1 = line[c.seg], p2 = line[c.seg + 1];
  if (!p1 || !p2) return null;
  const raw = segmentVector(line, c.seg, true), pos = lineLanePoint(line, c.seg, c.t, c.fwd, c.lane);
  return { pos, angle: Math.atan2(raw.n, raw.e) + (c.fwd ? 0 : Math.PI) };
}
function vehicleLength(c) { return c.hitbox?.length || c.length || VEHICLE_TYPES[c.type === 'truck' ? 'truck' : 'car'].length; }
function vehicleWidth(c) { return c.hitbox?.width || c.width || VEHICLE_TYPES[c.type === 'truck' ? 'truck' : 'car'].width; }
function turnLead(c) { return Math.min(7.5, Math.max(2.6, 1.8 + (c.v || 0) * .34 + (c.type === 'truck' ? 1.4 : 0))); }
function turnSpeedLimit(c, incoming, outgoing, curveLength) {
  const bend = Math.abs(angleDelta(outgoing, incoming)); if (bend < .16) return c.maxSpd;
  const spec = VEHICLE_TYPES[c.type === 'truck' ? 'truck' : 'car'], radius = Math.max(2.8, curveLength * .55);
  return Math.min(c.maxSpd, Math.max(3.0, Math.sqrt((spec.maxLatAccel || 6) * radius)));
}
function makeCar(line, fwd, forceTruck, initialT) {
  if (lineMeta(line).oneWay) fwd = true;
  const isTruck = forceTruck == null ? Math.random() < (state.alleys.includes(line) ? .14 : .18) : forceTruck;
  const type = isTruck ? 'truck' : 'car', spec = VEHICLE_TYPES[type], maxSpd = rand(spec.minSpeed, spec.maxSpeed), lane = lineMeta(line).oneWay ? randInt(2) : 0;
  const car = {
    id: ++_vehicleId,
    line, seg: randInt(Math.max(1, line.length - 1)), t: initialT == null ? Math.random() : initialT, fwd: fwd == null ? Math.random() < .5 : fwd, lane,
    type, length: spec.length, width: spec.width, hitbox: { length: spec.length, width: spec.width }, maxSpd, spd: maxSpd,
    accel: spec.accel * rand(.85, 1.15), brake: spec.brake * rand(.9, 1.1), v: 0,
    trailerAngle: null, trailerWheelbase: spec.trailerWheelbase || 0, nextTurn: null, route: [], color: (isTruck ? TRUCK_COLORS : CAR_COLORS)[randInt((isTruck ? TRUCK_COLORS : CAR_COLORS).length)]
  };
  prepareRandomRoute(car);
  return car;
}
function spawnCar(line, fwd, forceTruck) {
  if (lineMeta(line).oneWay) fwd = true;
  const c = makeCar(line, fwd, forceTruck), total = roadLen(line), last = line.length - 2;
  if (total < 1 || !sim.cars.length) return c;
  const entries = [{ atEnd: false, fwd: true }];
  if (!lineMeta(line).oneWay) entries.push({ atEnd: true, fwd: false });
  const externalEntries = entries.filter(entry => lineEndpointExit(line, entry.atEnd, 'road'));
  if (externalEntries.length && Math.random() < .3) {
    const entry = externalEntries[randInt(externalEntries.length)];
    c.fwd = entry.fwd; c.seg = entry.atEnd ? last : 0; c.t = entry.atEnd ? .985 : .015; c.lane = lineMeta(line).oneWay ? randInt(2) : 0;
    return c;
  }
  let best = null, bestGap = -Infinity, fallback = null, fallbackGap = -Infinity;
  for (let k = 0; k < 18; k++) {
    const distance = total * (k + .5) / 18;
    const at = fwd ? lineStateAfter(line, 0, 0, true, distance) : lineStateAfter(line, last, 1, false, distance);
    const progress = lineProgress(line, at.seg, at.t, fwd), sameLane = sim.cars.filter(o => o.line === line && trafficLaneKey(o.line, o.fwd, o.lane) === trafficLaneKey(line, fwd, c.lane) && !o.turn);
    const gap = sameLane.length ? Math.min(...sameLane.map(o => Math.abs(progress - lineProgress(o.line, o.seg, o.t, o.fwd)) - (vehicleLength(c) + vehicleLength(o)) / 2 - 2.2)) : Infinity;
    c.seg = at.seg; c.t = at.t;
    const collides = sim.cars.some(o => trafficSpawnTooClose(c, o));
    if (gap > fallbackGap) { fallbackGap = gap; fallback = at; }
    if (!collides && gap > bestGap) { bestGap = gap; best = at; }
    if (!collides && gap >= 0) break;
  }
  const selected = best || fallback;
  if (selected) { c.seg = selected.seg; c.t = selected.t; }
  return c;
}
const NAME_M = ['Иван', 'Пётр', 'Алексей', 'Дмитрий', 'Сергей', 'Андрей', 'Николай', 'Михаил', 'Олег', 'Артём', 'Максим', 'Роман', 'Егор', 'Кирилл', 'Фёдор', 'Павел', 'Денис', 'Глеб'];
const NAME_F = ['Анна', 'Мария', 'Елена', 'Ольга', 'Татьяна', 'Ирина', 'Наталья', 'Светлана', 'Юлия', 'Дарья', 'Екатерина', 'Софья', 'Полина', 'Вера', 'Алиса', 'Ксения', 'Нина'];
const SURNAME = ['Иванов', 'Петров', 'Смирнов', 'Кузнецов', 'Соколов', 'Попов', 'Лебедев', 'Козлов', 'Новиков', 'Морозов', 'Волков', 'Орлов', 'Зайцев', 'Фролов', 'Гусев', 'Беляев'];
const JOBS = ['рабочий', 'учитель', 'врач', 'продавец', 'инженер', 'студент', 'пенсионер', 'водитель', 'повар', 'программист', 'строитель', 'бухгалтер', 'музыкант', 'садовник', 'почтальон'];
let _cid = 0;
function makeCitizen(line) {
  const female = Math.random() < 0.5;
  const first = female ? NAME_F[randInt(NAME_F.length)] : NAME_M[randInt(NAME_M.length)];
  const last = SURNAME[randInt(SURNAME.length)] + (female ? 'а' : '');
  const cit = {
    id: ++_cid, name: first + ' ' + last, female, age: 16 + randInt(64), job: JOBS[randInt(JOBS.length)],
    line, seg: randInt(Math.max(1, line.length - 1)), t: Math.random(), fwd: Math.random() < .5,
    spd: 1.0 + Math.random() * 0.7, color: PED_COLORS[randInt(PED_COLORS.length)],
    dest: null, goal: null, status: 'идёт', idle: 0, transit: null, waitingAtStation: null, waitSlot: null,
    route: null, routeIdx: 0, stepEnd: null,
    home: null, work: null, employed: false, atWork: false
  };
  assignCitizenJob(cit);
  return cit;
}
// Дом и рабочее место: работа выдаётся по свободным местам магазинов
function assignCitizenJob(cit) {
  const houses = state.buildings.filter(b => b.type === 'house' && isFinite(b.lat) && isFinite(b.lng));
  const shops = state.buildings.filter(b => b.type === 'shop' && isFinite(b.lat) && isFinite(b.lng));
  if (houses.length) cit.home = houses[cit.id % houses.length];
  cit.work = null; cit.employed = false;
  if (!shops.length) return;
  let best = null, bestLoad = Infinity;
  for (const s of shops) {
    const load = sim.workload.get(s) || 0;
    if (load < bestLoad) { bestLoad = load; best = s; }
  }
  if (best && bestLoad < JOBS_PER_SHOP) {
    cit.work = best; cit.employed = true;
    sim.workload.set(best, bestLoad + 1);
  }
}
function citizenWorkplace(cit) { return cit && cit.work ? cit.work : null; }
function exitNearPoint(point, mode, radius = 10) {
  if (!point || !Array.isArray(state.exits)) return null;
  return state.exits.find(x => Array.isArray(x.modes) && x.modes.includes(mode) && distMeters(x.lat, x.lng, point[0], point[1]) <= radius) || null;
}
function railExitsAll() { return (state.exits || []).filter(x => Array.isArray(x.modes) && x.modes.includes('rail')); }
function railLinesAtExit(exit) {                          // линии ЖД, концы которых у точки выезда
  const out = [];
  for (let i = 0; i < (sim.railLines || []).length; i++) {
    const L = sim.railLines[i];
    if (distMeters(exit.lat, exit.lng, L[0][0], L[0][1]) <= 8) out.push({ i, atEnd: false });
    else if (distMeters(exit.lat, exit.lng, L[L.length - 1][0], L[L.length - 1][1]) <= 8) out.push({ i, atEnd: true });
  }
  return out;
}
function railExitEndFor(line, nextLine) {                 // к какому концу line ехать, чтобы стыковаться с nextLine
  const tol = Math.max(5, LINE_M.rail * .95), ends = [{ atEnd: false, p: line[0] }, { atEnd: true, p: line[line.length - 1] }];
  for (const e of ends) for (let s = 1; s < nextLine.length; s++) {
    const h = projOnSegLL(e.p, nextLine[s - 1], nextLine[s]);
    if (distMeters(e.p[0], e.p[1], h[0], h[1]) <= tol) return e.atEnd;
  }
  return null;
}
function buildTrainRoute(train, targetExit) {             // BFS по сети ЖД от текущей линии до линии у targetExit
  train._routeGoal = targetExit ? railExitSimKey(targetExit) : null;
  train.route = [];
  if (!targetExit || !train.line || !(sim.railLines || []).length) return false;
  const railLines = sim.railLines, startIdx = railLines.indexOf(train.line), tol = Math.max(5, LINE_M.rail * .95);
  if (startIdx < 0) return false;
  const adj = railLines.map(() => []);
  for (let i = 0; i < railLines.length; i++) for (let j = i + 1; j < railLines.length; j++) {
    const A = railLines[i], B = railLines[j]; let conn = false;
    const touches = (p, L) => { for (let s = 1; s < L.length && !conn; s++) { const h = projOnSegLL(p, L[s - 1], L[s]); if (distMeters(p[0], p[1], h[0], h[1]) <= tol) conn = true; } };
    touches(A[0], B); if (!conn && A.length) touches(A[A.length - 1], B);
    if (!conn) { touches(B[0], A); if (!conn && B.length) touches(B[B.length - 1], A); }
    if (conn) { adj[i].push(j); adj[j].push(i); }
  }
  const goals = railLinesAtExit(targetExit).map(x => x.i), prev = new Map([[startIdx, -1]]);
  let queue = [startIdx], found = -1;
  while (queue.length && found < 0) { const next = []; for (const u of queue) if (goals.includes(u)) { found = u; break; } for (const u of queue) { if (found >= 0) break; for (const v of adj[u]) if (!prev.has(v)) { prev.set(v, u); next.push(v); } } queue = next; }
  if (found < 0) return false;
  const path = []; for (let x = found; x >= 0; x = prev.get(x)) path.unshift(x);
  if (path.length === 1) {                                   // цель на стартовой линии: маршрут возможен, только если поезд уже едет к её концу у выезда
    const goalAtEnd = railLinesAtExit(targetExit).find(x => x.i === found);
    if (train.fwd ? !goalAtEnd.atEnd : goalAtEnd.atEnd) return false;
    train.route = [];
    return true;
  }
  if (path.length > 1) {                                     // первый переход обязан вести к тому концу линии, куда поезд едет
    const firstHopEnd = railExitEndFor(railLines[path[0]], railLines[path[1]]);
    if (train.fwd ? !firstHopEnd : !!firstHopEnd) return false;
  }
  const goalAtEnd = railLinesAtExit(targetExit).find(x => x.i === found);
  const route = [];
  for (let k = 1; k < path.length; k++) {
    const atEnd = k === path.length - 1 ? (goalAtEnd ? goalAtEnd.atEnd : true) : (railExitEndFor(railLines[path[k]], railLines[path[k + 1]]) || false);
    route.push({ line: railLines[path[k]], fwd: atEnd, point: null });
  }
  if (route.length) train.route = route;
  return train.route.length > 0;
}
function prepareCitizenEntry(cit) {
  if (!cit || !cit.line || cit.line.length < 2) return cit;
  const last = cit.line.length - 2, entries = [{ atEnd: false, fwd: true }, { atEnd: true, fwd: false }].filter(entry => exitNearPoint(entry.atEnd ? cit.line[cit.line.length - 1] : cit.line[0], 'walk', 12));
  if (entries.length && Math.random() < .35) { const entry = entries[randInt(entries.length)]; cit.fwd = entry.fwd; cit.seg = entry.atEnd ? last : 0; cit.t = entry.atEnd ? .985 : .015; }
  return cit;
}
function stationRailLines(station) {                     // обе линии станции (или ближайшая как fallback)
  const lines = [];
  for (const key of [station.railKey, station.railKey2]) {
    if (!key) continue;
    const line = state.rails.find(l => roadKey(l) === key);
    if (line && line.length >= 2 && !lines.includes(line)) lines.push(line);
  }
  if (!lines.length) { const hit = nearestRailPointForStation(station); if (hit && hit.line) lines.push(hit.line); }
  return lines;
}
function stationSideForTrain(station, train) {           // сторона платформы относительно конкретного поезда
  const g = stationGeometry(station), fallback = g.platformSide || (station.side == null ? 1 : station.side);
  if (!train || !train.line || !train.line[train.seg + 1]) return fallback;
  const pose = lerpPos(train.line, train.seg, train.t), tan = segmentVector(train.line, train.seg, train.fwd);
  const de = (g.platformMid[1] - pose[1]) * mPerDegLng(pose[0]), dn = (g.platformMid[0] - pose[0]) * MPD_LAT;
  const proj = de * (-tan.n) + dn * tan.e;               // проекция на левую нормаль курса
  return proj >= 0 ? 1 : -1;
}
function railBendBetween(line, seg, fwd, otherLine, otherSeg, otherFwd) {   // отклонение курса при переходе (радианы)
  const a = segmentVector(line, seg, fwd), b = segmentVector(otherLine, otherSeg, otherFwd);
  return Math.abs(angleDelta(Math.atan2(a.n, a.e), Math.atan2(b.n, b.e)));
}
function railJunctionOptions(train, endpoint, returnAll = false) {          // стыки рельсов: только плавные по курсу
  const options = [], current = train.line, tol = Math.max(5, LINE_M.rail * .95);
  const incomingAngle = Math.atan2(segmentVector(current, train.seg, train.fwd).n, segmentVector(current, train.seg, train.fwd).e);
  const prev = train.seg > 0 ? segmentVector(current, train.seg - 1, train.fwd) : null;
  const prevAngle = prev ? Math.atan2(prev.n, prev.e) : incomingAngle;
  for (const line of sim.railLines || []) {
    if (line === current || line.length < 2) continue;
    if (lineIsClosed(line)) continue;                          // кольцо не стыкуется со случайными линиями в середине
    for (let i = 1; i < line.length; i++) {
      const hit = projOnSegLL(endpoint, line[i - 1], line[i]), distance = distMeters(endpoint[0], endpoint[1], hit[0], hit[1]);
      if (distance > tol) continue;
      const segLen = distMeters(line[i - 1][0], line[i - 1][1], line[i][0], line[i][1]) || 1;
      const t = Math.max(0, Math.min(1, distMeters(line[i - 1][0], line[i - 1][1], hit[0], hit[1]) / segLen));
      for (const fwd of [true, false]) {
        if ((fwd ? 1 - t : t) * segLen < .45) continue;
        const bend = railBendBetween(current, train.seg, train.fwd, line, i - 1, fwd);
        // отсекаем резкие повороты: разрешено продолжение почти по курсу или плавный изгиб (<= 70°),
        // U-разворот на 180° оставляем только как крайний случай (нет других путей)
        if (bend > Math.PI * .39 && bend < Math.PI * .8) continue;
        options.push({ line, seg: i - 1, t, fwd, point: hit, distance, bend });
      }
      break;
    }
  }
  if (!options.length) return null;
  options.sort((a, b) => (a.bend || 0) - (b.bend || 0));
  if (returnAll) return options;
  // маршрут до станции: если он есть и совпадает с опцией — почти всегда туда
  const planned = train.route && train.route[0];
  if (planned) {
    const matches = options.filter(o => o.line === planned.line && o.fwd === planned.fwd);
    if (matches.length) {
      const picked = planned.point ? matches.sort((a, b) => distMeters(a.point[0], a.point[1], planned.point[0], planned.point[1]) - distMeters(b.point[0], b.point[1], planned.point[0], planned.point[1]))[0] : matches[0];
      train.route.shift();
      return picked;
    }
    train.route = [];
  }
  // прямо по курсу: берём самый плавный изгиб; случайность — только среди почти прямых (±12° от лучшего)
  const bestBend = options[0].bend || 0, nearStraight = options.filter(o => (o.bend || 0) <= bestBend + Math.PI / 15);
  return nearStraight[randInt(nearStraight.length)];
}
function makeTrain(line, fwd, initialT) {
  const direction = fwd == null ? Math.random() < .5 : fwd;
  let seg = randInt(Math.max(1, line.length - 1)), t = initialT == null ? Math.random() : initialT, enterFwd = direction, entryExit = null;
  const entries = [{ atEnd: false, fwd: true }, { atEnd: true, fwd: false }].filter(entry => exitNearPoint(entry.atEnd ? line[line.length - 1] : line[0], 'rail', 10));
  if (entries.length && Math.random() < .6) {
    const entry = entries[randInt(entries.length)], endpoint = entry.atEnd ? line[line.length - 1] : line[0];
    entryExit = exitNearPoint(endpoint, 'rail', 10); enterFwd = entry.fwd; seg = entry.atEnd ? line.length - 2 : 0; t = entry.atEnd ? .985 : .015;
  }
  // 8 вагонов: локомотив (i=0) — голова, ведёт; прицепные следуют за ним с фикс. сцепкой
  const wagons = [];
  for (let i = 0; i < TRAIN_WAGONS; i++) wagons.push({ i, len: TRAIN_WAGON_LEN, w: TRAIN_WIDTH, pos: null, angle: 0, hitchAngle: 0, couplDist: TRAIN_COUPLING });
  const train = { id: ++_trainId, line, seg, t, fwd: enterFwd, v: rand(12, 16), maxSpd: rand(27, 34), accel: 8, brake: 20, wagons, length: TRAIN_WAGONS * TRAIN_COUPLING, width: TRAIN_WIDTH, dwell: 0, stationKey: null, passengers: [], inboundPassengers: entryExit ? 4 + randInt(11) : 0, entryExit, dead: false, pos: null, angle: 0, route: [] };
  assignTrainRoute(train);
  return train;
}
function assignTrainRoute(train) {                    // явный маршрут: между точками выезда, или город → ближайшая точка выезда
  const all = railExitsAll();
  let goal = null;
  if (train._routeGoal) {                             // курсирующий (развернулся у выхода): едем к любой другой точке выезда
    const others = all.filter(x => railExitSimKey(x) !== train._routeGoal);
    if (others.length) goal = others[randInt(others.length)];
    train.entryExit = null;
  } else if (train.entryExit) {                       // спавн из точки выезда: едем к другой точке выезда в мире
    const others = all.filter(x => x !== train.entryExit);
    goal = others[randInt(others.length)] || train.entryExit;
  } else {                                            // городской поезд: к ближайшей точке выезда
    const pose = trainPose(train);
    goal = all.sort((a, b) => distMeters(pose.pos[0], pose.pos[1], a.lat, a.lng) - distMeters(pose.pos[0], pose.pos[1], b.lat, b.lng))[0] || null;
  }
  buildTrainRoute(train, goal);
}
function parkingSlotPosition(lot, slot) {
  const parking = lot.parking, capacity = Math.max(2, Math.min(20, Math.round(Number(parking.capacity) || 6))), angle = (Number(parking.rot) || 0) * Math.PI / 180;
  const along = -parking.w / 2 + parking.w * (slot + .5) / capacity;
  return offset(parking.lat, parking.lng, Math.cos(angle) * along, Math.sin(angle) * along);
}
function parkingAccessRecords(lines) {
  return state.parking.map(parking => {
    let best = null;
    for (const line of lines) for (let segment = 1; segment < line.length; segment++) {
      const point = projOnSegLL([parking.lat, parking.lng], line[segment - 1], line[segment]), distance = distMeters(parking.lat, parking.lng, point[0], point[1]);
      if (!best || distance < best.distance) best = { line, segment: segment - 1, point, distance };
    }
    if (!best || best.distance > 24) return null;
    return { parking, line: best.line, segment: best.segment, point: best.point, distance: best.distance };
  }).filter(Boolean);
}
function maybeParkCar(car, dt) {
  if (!sim.parkingLots?.length || car.turn || (car.v || 0) < 1) return false;
  const pose = smoothCarPose(car); if (!pose) return false;
  const totalSlots = sim.parkingLots.reduce((sum, lot) => sum + Math.max(2, Math.min(20, Math.round(Number(lot.parking.capacity) || 6))), 0);
  const arrivalRate = totalSlots * .42 / (Math.max(1, sim.cars.length) * 38);
  if (Math.random() >= Math.min(.015, arrivalRate * dt)) return false;
  const candidates = sim.parkingLots.filter(lot => lot.line === car.line && distMeters(pose.pos[0], pose.pos[1], lot.point[0], lot.point[1]) <= 13)
    .sort((a, b) => distMeters(pose.pos[0], pose.pos[1], a.point[0], a.point[1]) - distMeters(pose.pos[0], pose.pos[1], b.point[0], b.point[1]));
  for (const lot of candidates) {
    const capacity = Math.max(2, Math.min(20, Math.round(Number(lot.parking.capacity) || 6))), occupied = new Set(sim.parkedCars.filter(actor => actor.lot === lot).map(actor => actor.slot));
    let slot = 0; while (slot < capacity && occupied.has(slot)) slot++; if (slot >= capacity) continue;
    const target = parkingSlotPosition(lot, slot), angle = (Number(lot.parking.rot) || 0) * Math.PI / 180 + Math.PI / 2;
    sim.parkedCars.push({ type: car.type, length: car.length, width: car.width, hitbox: car.hitbox, color: car.color, trailerWheelbase: car.trailerWheelbase, trailerAngle: pose.angle, lot, slot, phase: 'entering', from: pose.pos, to: target, pos: pose.pos, fromAngle: pose.angle, toAngle: angle, angle: pose.angle, elapsed: 0, duration: 1.35, dwell: 18 + Math.random() * 45, exitPoint: lot.point });
    car.dead = true; return true;
  }
  return false;
}
function stepParkingCars(dt) {
  for (const actor of sim.parkedCars) {
    if (actor.phase === 'parked') {
      actor.dwell -= dt;
      if (actor.dwell <= 0) { actor.phase = 'leaving'; actor.elapsed = 0; actor.duration = 1.35; actor.from = actor.pos; actor.to = actor.exitPoint; actor.fromAngle = actor.angle; actor.toAngle = (Number(actor.lot.parking.rot) || 0) * Math.PI / 180; }
    } else {
      actor.elapsed += dt; const t = Math.min(1, actor.elapsed / actor.duration);
      actor.pos = [actor.from[0] + (actor.to[0] - actor.from[0]) * t, actor.from[1] + (actor.to[1] - actor.from[1]) * t];
      actor.angle = actor.fromAngle + angleDelta(actor.toAngle, actor.fromAngle) * t; actor.trailerAngle = actor.angle;
      if (t >= 1) { if (actor.phase === 'entering') { actor.phase = 'parked'; actor.dwell = 18 + Math.random() * 45; } else actor.dead = true; }
    }
  }
  sim.parkedCars = sim.parkedCars.filter(actor => !actor.dead);
}
function stationSimKey(station) { return station ? `${Number(station.lat).toFixed(5)}:${Number(station.lng).toFixed(5)}` : ''; }
function stationBySimKey(key) { return state.stations.find(station => stationSimKey(station) === key) || null; }
function railExitSimKey(exit) { return exit ? `${exit.name || ''}:${Number(exit.lat).toFixed(5)}:${Number(exit.lng).toFixed(5)}` : ''; }
function railLinesJoin(a, b) {
  const tol = Math.max(5, LINE_M.rail * .95), endpointsA = [a[0], a[a.length - 1]], endpointsB = [b[0], b[b.length - 1]];
  const endpointTouches = (point, line) => { for (let i = 1; i < line.length; i++) if (pointSegDistM(point[0], point[1], line[i - 1], line[i]) <= tol) return true; return false; };
  return endpointsA.some(point => endpointTouches(point, b)) || endpointsB.some(point => endpointTouches(point, a));
}
function railComponentLines(startLine) {
  const lines = sim.railLines || state.rails, component = new Set(startLine ? [startLine] : []), queue = startLine ? [startLine] : [];
  while (queue.length) {
    const line = queue.shift();
    for (const other of lines) if (!component.has(other) && other.length >= 2 && railLinesJoin(line, other)) { component.add(other); queue.push(other); }
  }
  return component;
}
function passengerDestinationForTrain(train, origin) {
  const component = railComponentLines(train.line), destinations = state.stations.filter(station => station !== origin && sim.stationAccess?.has(station) && stationRailLines(station).some(line => component.has(line)));
  const exits = [];
  for (const line of component) for (const atEnd of [false, true]) {
    const exit = lineEndpointExit(line, atEnd, 'rail'); if (exit && !exits.includes(exit)) exits.push(exit);
  }
  if (destinations.length && (!exits.length || Math.random() < .72)) {
    const station = destinations[randInt(destinations.length)]; return { type: 'station', stationKey: stationSimKey(station), name: station.name || 'другая станция' };
  }
  if (exits.length) { const exit = exits[randInt(exits.length)]; return { type: 'exit', exitKey: railExitSimKey(exit), name: exit.name || 'выезд из города' }; }
  if (destinations.length) { const station = destinations[randInt(destinations.length)]; return { type: 'station', stationKey: stationSimKey(station), name: station.name || 'другая станция' }; }
  return null;
}
function setCitizenAtStation(pedestrian, station, startWalking = false) {
  const access = sim.stationAccess?.get(station); if (!access) return false;
  pedestrian.dead = false; pedestrian.transit = null; pedestrian.waitingAtStation = null; pedestrian.waitSlot = null;
  pedestrian.goal = null; pedestrian.dest = null; pedestrian.idle = 0;
  pedestrian.line = access.networkLine; pedestrian.seg = access.segment; pedestrian.t = access.t; pedestrian.fwd = true;
  if (startWalking) { pedestrian.status = 'вышел на станции'; assignDest(pedestrian, { avoidTransit: true }); return true; }
  pedestrian.waitingAtStation = station; pedestrian.waitSlot = sim.peds.filter(other => other !== pedestrian && other.waitingAtStation === station).length;
  pedestrian.transit = { state: 'waiting', stationKey: stationSimKey(station) }; pedestrian.status = `ждёт поезд · ${station.name || 'станция'}`;
  return true;
}
function spawnInboundPassengers(train, station) {
  const available = Math.min(Math.max(0, train.inboundPassengers || 0), Math.max(0, 500 - sim.peds.length));
  let created = 0;
  for (; created < available; created++) {
    const access = sim.stationAccess.get(station), line = access && access.networkLine;
    if (!line || line.length < 2) break;
    const pedestrian = makeCitizen(line);
    if (!setCitizenAtStation(pedestrian, station, true)) break;
    sim.peds.push(pedestrian);
  }
  train.inboundPassengers = Math.max(0, (train.inboundPassengers || 0) - created);
}
function boardingCount(train) { return sim.peds.filter(p => p._board && p._board.train === train).length; }
function startBoarding(p, train, station, slot, side) {      // ожидающий подходит к двери вагона и садится
  const door = trainDoorPos(train, slot, side, station), from = stationQueuePosition(station, p.waitSlot || 0);
  p._board = { train, station, from, to: door, t: 0, dur: rand(0.9, 1.5), slot, requestedDestination: (p.transit && p.transit.requestedDestination) || null };
  p.transit = { state: 'boarding', stationKey: stationSimKey(station) };
  p.waitingAtStation = null; p.waitSlot = null; p.goal = null;
  p.status = 'садится в поезд';
}
function startAlight(p, train, station, slot, side) {         // пассажир выходит из вагона на платформу
  const door = trainDoorPos(train, slot, side, station), to = stationQueuePosition(station, sim.peds.filter(o => o !== p && o.waitingAtStation === station).length);
  p._board = { train, station, from: door, to, t: 0, dur: rand(0.9, 1.5), alight: true };
  p.transit = { state: 'boarding', stationKey: stationSimKey(station) };
  p.status = 'выходит из поезда';
}
function handleTrainStationStop(train, station) {
  if (!Array.isArray(train.passengers)) train.passengers = [];
  const key = stationSimKey(station), side = stationSideForTrain(station, train), remaining = [];
  for (let i = 0; i < train.passengers.length; i++) {
    const passenger = train.passengers[i], destination = passenger.transit?.destination;
    if (destination?.type === 'station' && destination.stationKey === key) {
      if (destination.finalGoal) passenger._alightFinal = destination;   // цель после выхода — дойдёт пешком
      startAlight(passenger, train, station, i, side);
    } else remaining.push(passenger);
  }
  train.passengers = remaining;
  if (train.inboundPassengers > 0) spawnInboundPassengers(train, station);
  const capacity = 80;
  for (const pedestrian of sim.peds) {
    if (train.passengers.length + boardingCount(train) >= capacity) break;
    if (pedestrian.transit?.state !== 'waiting' || pedestrian.transit.stationKey !== key) continue;
    const destination = pedestrian.transit.requestedDestination || passengerDestinationForTrain(train, station); if (!destination) continue;
    const slot = train.passengers.length + boardingCount(train);
    startBoarding(pedestrian, train, station, slot, side);
  }
}
function handleTrainRailExit(train, exit) {
  const exitKey = railExitSimKey(exit), remaining = [];
  for (const passenger of train.passengers || []) {
    const destination = passenger.transit?.destination;
    if (destination?.type === 'exit' && destination.exitKey === exitKey) passenger.dead = true;
    else remaining.push(passenger);
  }
  train.passengers = remaining; train.inboundPassengers = 0;
  if (!remaining.length && !train._routeGoal) train.dead = true;   // поезд без маршрута (случайный) уезжает из мира
}
function trainProgress(train) { return lineProgress(train.line, train.seg, train.t, train.fwd); }
function trainFrontGap(train) {
  let best = Infinity, progress = trainProgress(train);
  for (const other of sim.trains || []) {
    if (other === train || other.dead || other.line !== train.line || other.fwd !== train.fwd) continue;
    const delta = trainProgress(other) - progress;
    if (delta > 0) best = Math.min(best, delta - (train.length + other.length) / 2 - 2);
  }
  return best;
}
function trainLinePlans() {
  const lines = (sim.railLines || state.rails || []).filter(line => line && line.length >= 2), settings = simulationSettings();
  const totalLength = lines.reduce((sum, line) => sum + roadLen(line), 0);
  const total = settings.trainMode === 'fixed' ? settings.trainCount : (lines.length ? Math.min(80, Math.max(1, Math.round(totalLength / 900) + (state.stations.length ? 1 : 0))) : 0);
  const targets = allocateTrafficTargets(lines, total);
  return lines.map((line, i) => ({ line, target: targets[i], count: 0 }));
}
function addTrainsFair(plans) {
  const targetTotal = plans.reduce((sum, plan) => sum + plan.target, 0); let added = true;
  while (sim.trains.length < targetTotal && added) {
    added = false;
    for (const plan of plans) {
      if (plan.count >= plan.target || sim.trains.length >= targetTotal) continue;
      sim.trains.push(makeTrain(plan.line, plan.count % 2 === 0)); plan.count++; added = true;
    }
  }
}
function replenishTrains() {
  sim.railLines = state.rails.filter(line => line && line.length >= 2);
  const counts = new Map(); for (const train of sim.trains) if (!train.dead && train.line) counts.set(train.line, (counts.get(train.line) || 0) + 1);
  const plans = trainLinePlans(); plans.forEach(plan => { plan.count = counts.get(plan.line) || 0; });
  addTrainsFair(plans);
}
function trainTurnPose(train) {                        // позиция поезда на дуге поворота
  const tr = train.turn; if (!tr || !tr.samples.length) return null;
  let i = 1; while (i < tr.cum.length - 1 && tr.cum[i] < tr.s) i++;
  const a = tr.samples[i - 1], b = tr.samples[i], span = tr.cum[i] - tr.cum[i - 1] || 1;
  const f = Math.max(0, Math.min(1, (tr.s - tr.cum[i - 1]) / span)), pos = [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f];
  const p0 = tr.samples[Math.max(0, i - 2)], p1 = tr.samples[Math.min(tr.samples.length - 1, i + 1)];
  const e = (p1[1] - p0[1]) * mPerDegLng(pos[0]), n = (p1[0] - p0[0]) * MPD_LAT;
  return { pos, angle: Math.atan2(n, e) };
}
function trainFrontPose(train) {                     // позиция носа (головы состава) — по ЖД пути или дуге поворота
  if (train.turn) { const p = trainTurnPose(train); if (p) return p; }
  if (!train.line || !train.line[train.seg + 1]) return null;
  const raw = segmentVector(train.line, train.seg, train.fwd), pos = lerpPos(train.line, train.seg, train.t);
  return { pos, angle: Math.atan2(raw.n, raw.e) };
}
function trainPose(train) { return trainFrontPose(train); }
// Расстановка вагонов от головы: каждый следующий — на фиксированную дистанцию позади
// по направлению тела предыдущего (кинематическая цепь). Так промежутки не меняются на
// поворотах, а состав плавно изгибается (как у грузовика с прицепом).
// Поза точки на дуге поворота по накопленной дистанции s (обобщение trainTurnPose)
function curvePoseAt(tr, s) {
  const c = tr.cum; if (!c || !c.length) return null;
  if (s <= c[0] + 1e-9) { const p0 = tr.samples[0], p1 = tr.samples[Math.min(tr.samples.length - 1, 1)]; const e = (p1[1] - p0[1]) * mPerDegLng(p0[0]), n = (p1[0] - p0[0]) * MPD_LAT; return { pos: p0, angle: Math.atan2(n, e || 1) }; }
  let i = 1; while (i < c.length - 1 && c[i] < s) i++;
  const a = tr.samples[i - 1], b = tr.samples[i], span = c[i] - c[i - 1] || 1;
  const f = Math.max(0, Math.min(1, (s - c[i - 1]) / span)), pos = [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f];
  const p0 = tr.samples[Math.max(0, i - 2)], p1 = tr.samples[Math.min(tr.samples.length - 1, i + 1)];
  const e = (p1[1] - p0[1]) * mPerDegLng(pos[0]), n = (p1[0] - p0[0]) * MPD_LAT;
  return { pos, angle: Math.atan2(n, e) };
}
// Поза точки на полилинии на distBack метров к «хвосту» от (seg,t) по направлению движения
function lineBackwardPose(line, seg, t, fwd, distBack) {
  let s = Math.max(0, Math.min(line.length - 2, seg)), u = Math.max(0, Math.min(1, t)), left = Math.max(0, distBack), guard = 0;
  while (left > 1e-6 && guard++ < line.length + 4) {
    const a = line[s], b = line[s + 1]; if (!a || !b) break;
    const len = distMeters(a[0], a[1], b[0], b[1]) || 1;
    const available = fwd ? u * len : (1 - u) * len;
    if (left <= available + 1e-6) { u -= (fwd ? 1 : -1) * left / len; const p = lerpPos(line, s, u); const tan = tangentAt(line, s); return { pos: p, angle: Math.atan2(tan.n, tan.e) }; }
    left -= available;
    if (fwd) { if (s <= 0) break; s--; u = 1; } else { if (s >= line.length - 2) break; s++; u = 0; }
  }
  const a = line[Math.max(0, Math.min(line.length - 2, s))], b = line[a === line[line.length - 1] ? line.length - 2 : Math.min(line.length - 1, s + 1)];
  const tan = a && b ? tangentAt(line, s) : { e: 1, n: 0 };
  return { pos: [a[0], a[1]], angle: Math.atan2(tan.n, tan.e) };
}
// Поза точки на distBack метров к хвосту от носа: сначала дуга поворота (если идём по ней),
// затем рельс, по которому поезд ехал до поворота. Так прицепные вагоны едут ПО рельсам.
function trainPointBehind(train, distBack) {
  if (distBack <= 1e-3) return trainFrontPose(train);
  let remaining = distBack;
  if (train.turn) {
    const tr = train.turn, headS = tr.s;
    if (remaining <= headS + 1e-6) { const p = curvePoseAt(tr, Math.max(0, headS - remaining)); if (p) return p; }
    remaining -= headS;
  }
  const line = train.line; if (!line || line.length < 2 || !line[train.seg + 1]) return trainFrontPose(train);
  return lineBackwardPose(line, train.seg, train.t, train.fwd, Math.max(0, remaining));
}
// Расстановка 8 вагонов от носа: каждый центр на фиксированной дистанции позже по пути —
// вагоны стоят на рельсах, промежутки не меняются, состав плавно изгибается на поворотах.
function updateTrainChain(train) {
  const head = trainFrontPose(train); if (!head) return;
  const wagons = train.wagons || []; if (!wagons.length) return;
  train.pos = head.pos; train.angle = head.angle;
  for (const w of wagons) {
    const distBack = TRAIN_WAGON_LEN / 2 + w.i * TRAIN_COUPLING;
    const p = trainPointBehind(train, distBack) || head;
    w.pos = p.pos; w.angle = p.angle; w.hitchAngle = p.angle;
  }
}
function buildTrainTurn(train, picked, endpoint, bend) {   // дуга поворота между текущим положением и новым путём
  const from = trainPose(train); if (!from) return null;
  const to = lineStateAfter(picked.line, picked.seg, picked.t, picked.fwd, 2.2);
  const toPos = lerpPos(to.line, to.seg, to.t);
  const center = picked.point ? [(endpoint[0] + picked.point[0]) / 2, (endpoint[1] + picked.point[1]) / 2] : endpoint;
  const control = offset(center[0], center[1], 0, 0);
  const curve = turnSamples(from.pos, control, toPos);
  const outFwd = segmentVector(to.line, to.seg, to.fwd);
  return { ...curve, s: 0, end: to, angle: Math.atan2(outFwd.n, outFwd.e), bend: bend || 0 };
}
function stationStopAhead(train, radius = 7) {        // ближайшая станция на текущей линии и дистанция до неё
  if (!train || !train.line || !Array.isArray(state.stations)) return null;
  const point = lerpPos(train.line, train.seg, train.t), key = roadKey(train.line);
  let best = null;
  for (const x of state.stations) {
    let d = null;
    if (x.railKey === key) d = distMeters(x.lat, x.lng, point[0], point[1]);
    else if (x.railKey2 === key) {
      const ref2 = stationRailRef2(x);
      if (ref2) d = distMeters(ref2.point[0], ref2.point[1], point[0], point[1]);
    } else {
      const dd = distMeters(x.lat, x.lng, point[0], point[1]);
      d = dd <= 2.5 ? dd : null;
    }
    if (d != null && d <= radius && (!best || d < best.dist)) best = { station: x, dist: d };
  }
  return best;
}
function stepTrain(train, dt) {
  if (train.dead || !train.line || train.line.length < 2 || !train.line[train.seg] || !train.line[train.seg + 1]) { train.dead = true; return; }
  const brake = train.brake || 20, comfort = brake * .6;   // тормозим мягче экстренного
  const stopDist = ((train.v || 0) ** 2) / (2 * comfort);
  const ahead = stationStopAhead(train, Math.max(7, stopDist + 4));
  if (ahead && train.stationKey !== ahead.station && ahead.dist <= .8 && (train.v || 0) <= 1.2) {
    train.stationKey = ahead.station; train.dwell = 3.2; train.v = 0; handleTrainStationStop(train, ahead.station);
  }
  if (train.dwell > 0) { train.dwell = Math.max(0, train.dwell - dt); train.v = Math.max(0, (train.v || 0) - brake * dt); return; }
  if (!ahead) train.stationKey = null;
  train.v = Math.min(train.maxSpd || 30, (train.v || 0) + (train.accel || 8) * dt);
  if (ahead && train.stationKey !== ahead.station) {       // подходим к станции: гасим по тормозной кривой
    const safe = Math.sqrt(Math.max(0, 2 * comfort * Math.max(0, ahead.dist - .4)));
    if (train.v > safe) train.v = safe;
  }
  let left = Math.max(0, train.v * dt), guard = 0;
  while (left > 1e-5 && guard++ < 10) {
    if (train.turn) {                                   // идём по дуге поворота
      const remain = train.turn.length - train.turn.s, moved = Math.min(left, remain);
      train.turn.s += moved; left -= moved;
      const curveLimit = train.turn.limit || train.maxSpd || 28;
      if (train.v > curveLimit) train.v = Math.max(curveLimit, train.v - (train.brake || 20) * dt);
      if (train.turn.s >= train.turn.length - 1e-4) {
        Object.assign(train, train.turn.end); train.turn = null; train.stationKey = null;
        if (left <= 1e-5) break; continue;
      }
      break;
    }
    const raw = segmentVector(train.line, train.seg, true), available = train.fwd ? (1 - train.t) * raw.len : train.t * raw.len;
    const gap = trainFrontGap(train), allowed = Math.max(0, Math.min(left, available, Number.isFinite(gap) ? gap : left));
    if (allowed <= 1e-5) { train.v = Math.max(0, train.v - (train.brake || 20) * dt); break; }
    train.t += (train.fwd ? 1 : -1) * allowed / raw.len; left -= allowed;
    if (allowed + 1e-5 < available) break;
    if (train.fwd && train.seg < train.line.length - 2) { train.seg++; train.t = 0; continue; }
    if (!train.fwd && train.seg > 0) { train.seg--; train.t = 1; continue; }
    const endpoint = train.fwd ? train.line[train.line.length - 1] : train.line[0];
    const out = exitNearPoint(endpoint, 'rail', 10);
    if (out && train._routeGoal && railExitSimKey(out) === train._routeGoal) {   // маршрутный поезд доехал до ЦЕЛЕВОЙ точки выезда — курсируем к другой
      handleTrainRailExit(train, out);
      if (train.dead) break;
      train.fwd = !train.fwd; train.t = train.fwd ? .015 : .985; train.stationKey = null; train.dwell = .8; train.v = 0;
      assignTrainRoute(train);
      break;
    }
    const options = railJunctionOptions(train, endpoint, true);
    if (options && options.length) {
      if (out) handleTrainRailExit(train, out);
      if (train.dead) break;
      const picked = railJunctionOptions(train, endpoint);
      const merged = Object.assign({}, picked, { line: picked.line });
      const bend = picked.bend || 0;
      const turn = buildTrainTurn(train, merged, endpoint, bend);
      if (turn && turn.length > 0.5) {
        const speedLimit = bend > 0.9 ? Math.min(train.maxSpd || 30, 18) : bend > 0.5 ? Math.min(train.maxSpd || 30, 24) : (train.maxSpd || 30);
        turn.limit = speedLimit;
        if (train.v > speedLimit) train.v = speedLimit;
        train.turn = turn;
      } else {
        Object.assign(train, lineStateAfter(picked.line, picked.seg, picked.t, picked.fwd, 2.2)); train.stationKey = null;
      }
    } else if (out) {
      handleTrainRailExit(train, out);
      if (train.dead) break;
      train.fwd = !train.fwd; train.t = train.fwd ? .015 : .985; train.stationKey = null; train.dwell = .8; train.v = 0;
      break;
    } else {
      train.fwd = !train.fwd; train.t = train.fwd ? .015 : .985; train.stationKey = null;
    }
  }
  updateTrainChain(train);                              // расставить 8 физических вагонов от головы
}
function simulationSettings() { state.simulation = normalizeSimulation(state.simulation); return state.simulation; }
function allocateTrafficTargets(lines, total) {
  const targets = Array(lines.length).fill(0); if (!lines.length || total <= 0) return targets;
  let remaining = Math.round(total);
  if (remaining >= lines.length) { targets.fill(1); remaining -= lines.length; }
  if (!remaining) return targets;
  const weights = lines.map(line => Math.max(12, roadLen(line))), weightSum = weights.reduce((a, b) => a + b, 0);
  const raw = weights.map(w => remaining * w / weightSum), base = raw.map(Math.floor);
  for (let i = 0; i < targets.length; i++) targets[i] += base[i];
  let left = remaining - base.reduce((a, b) => a + b, 0);
  raw.map((value, i) => ({ i, fraction: value - base[i] })).sort((a, b) => b.fraction - a.fraction).forEach(item => { if (left > 0) { targets[item.i]++; left--; } });
  return targets;
}
function autoCarCount(lines) {
  const totalLength = lines.reduce((sum, line) => sum + roadLen(line), 0);
  return Math.min(800, Math.max(lines.length ? lines.length * 2 : 0, Math.round(totalLength / 42)));
}
function trafficLinePlans() {
  const lines = state.roads.concat(state.alleys).filter(line => line && line.length >= 2), settings = simulationSettings();
  const total = settings.carMode === 'fixed' ? settings.carCount : autoCarCount(lines), targets = allocateTrafficTargets(lines, total);
  return lines.map((line, i) => ({ line, target: targets[i], count: 0 }));
}
function addTrafficFair(plans) {
  let added = true;
  const targetTotal = plans.reduce((sum, plan) => sum + plan.target, 0);
  while (sim.cars.length < targetTotal && added) {
    added = false;
    for (const plan of plans) {
      if (plan.count >= plan.target || sim.cars.length >= targetTotal) continue;
      const forceTruck = plan.target >= 4 && plan.count === plan.target - 1;
      sim.cars.push(spawnCar(plan.line, plan.count % 2 === 0, forceTruck ? true : undefined));
      plan.count++;
      added = true;
    }
  }
}
function buildSim() {
  sim.cars = []; sim.parkedCars = []; sim.parkingLots = []; sim.peds = []; sim.trains = []; sim._trafficLineCounts = new Map();
  sim.workload = new Map();
  sim.railLines = state.rails.filter(line => line && line.length >= 2);
  addTrainsFair(trainLinePlans());
  sim.driveLines = state.roads.concat(state.alleys);          // машины ездят по дорогам И переулкам
  sim.parkingLots = parkingAccessRecords(sim.driveLines);
  addTrafficFair(trafficLinePlans());
  const basePedLines = pedestrianBaseLines();
  sim.pedLines = basePedLines.slice();
  sim.pedNet = pedNetBuild(sim.pedLines);                      // граф сети для маршрутов жителей
  sim.stationAccess = new Map(); sim.transitStations = [];
  for (const station of state.stations) {
    const access = stationAccessInfo(station, basePedLines);
    if (!access) continue;
    sim.stationAccess.set(station, access); sim.transitStations.push(station);
  }
  basePedLines.forEach(line => { const n = Math.max(1, Math.round(roadLen(line) / 40)); for (let k = 0; k < n; k++) sim.peds.push(prepareCitizenEntry(makeCitizen(line))); });
  if (sim.cars.length > 800) sim.cars.length = 800;
  if (sim.peds.length > 500) sim.peds.length = 500;
  sim.selected = null; sim.follow = false;
  sim.peds.forEach(assignDest);                                // у каждого жителя — цель (куда направляется)
}
function replenishTraffic() {
  sim.driveLines = state.roads.concat(state.alleys);
  const counts = new Map();
  for (const c of sim.cars) if (!c.dead && c.line) counts.set(c.line, (counts.get(c.line) || 0) + 1);
  const plans = trafficLinePlans(); plans.forEach(plan => { plan.count = counts.get(plan.line) || 0; });
  let added = true, targetTotal = plans.reduce((sum, plan) => sum + plan.target, 0);
  while (sim.cars.length < targetTotal && added) {
    added = false;
    for (const plan of plans) {
      if (plan.count >= plan.target || sim.cars.length >= targetTotal) continue;
      const forceTruck = plan.target >= 4 && plan.count === plan.target - 1;
      sim.cars.push(spawnCar(plan.line, plan.count % 2 === 0, forceTruck ? true : undefined));
      plan.count++;
      added = true;
    }
  }
}
function pedNearestPoint(ll) {                                 // ближайшая точка пешеходной сети к latlng
  let best = null, bd = Infinity;
  for (const line of sim.pedLines) for (let i = 1; i < line.length; i++) {
    const pr = projOnSegLL([ll[0], ll[1]], line[i - 1], line[i]), d = distMeters(ll[0], ll[1], pr[0], pr[1]);
    if (d < bd) {
      const len = distMeters(line[i - 1][0], line[i - 1][1], line[i][0], line[i][1]) || 1;
      bd = d; best = { line, seg: i - 1, pos: pr, t: Math.max(0, Math.min(1, distMeters(line[i - 1][0], line[i - 1][1], pr[0], pr[1]) / len)) };
    }
  }
  return best;
}

/* ════════════ ПЕШЕХОДНАЯ СЕТЬ: ГРАФ И МАРШРУТЫ ════════════ */
const PED_SNAP_M = 1.5;                                     // узел считается лежащим на линии
function linePosOf(line, seg, t) {                          // (seg,t) → метры от начала линии
  let acc = 0;
  for (let s = 0; s < seg && s < line.length - 1; s++) acc += distMeters(line[s][0], line[s][1], line[s + 1][0], line[s + 1][1]);
  const len = distMeters(line[seg][0], line[seg][1], line[seg + 1][0], line[seg + 1][1]) || 1;
  return acc + Math.max(0, Math.min(1, t)) * len;
}
function lineSteps(line, posA, posB) {                      // участки одной линии от posA к posB
  const total = roadLen(line), a = Math.max(0, Math.min(total, posA)), b = Math.max(0, Math.min(total, posB));
  const lo = Math.min(a, b), hi = Math.max(a, b), out = [];
  if (hi - lo < 0.15) return out;
  let acc = 0;
  for (let s = 0; s < line.length - 1; s++) {
    const len = distMeters(line[s][0], line[s][1], line[s + 1][0], line[s + 1][1]) || 1, from = acc, to = acc + len; acc = to;
    const s0 = Math.max(from, lo), s1 = Math.min(to, hi);
    if (s1 - s0 < 0.15) continue;
    out.push({ line, seg: s, t0: (s0 - from) / len, t1: (s1 - from) / len });
  }
  if (a > b) out.reverse().forEach(st => { const tmp = st.t0; st.t0 = st.t1; st.t1 = tmp; });
  return out;
}
function segCrossPoint(a, b, c, d) {                        // пересечение двух отрезков (latlng)
  const m = mPerDegLng((a[0] + c[0]) / 2);
  const x1 = a[1] * m, y1 = a[0] * MPD_LAT, x2 = b[1] * m, y2 = b[0] * MPD_LAT;
  const x3 = c[1] * m, y3 = c[0] * MPD_LAT, x4 = d[1] * m, y4 = d[0] * MPD_LAT;
  const den = (x2 - x1) * (y4 - y3) - (y2 - y1) * (x4 - x3);
  if (Math.abs(den) < 1e-9) return null;
  const t = ((x3 - x1) * (y4 - y3) - (y3 - y1) * (x4 - x3)) / den;
  const u = ((x3 - x1) * (y2 - y1) - (y3 - y1) * (x2 - x1)) / den;
  if (t < -0.001 || t > 1.001 || u < -0.001 || u > 1.001) return null;
  return [(y1 + t * (y2 - y1)) / MPD_LAT, (x1 + t * (x2 - x1)) / m];
}
function pedNetBuild(lines) {                               // узлы-стыки + рёбра участками линий
  const nodes = [], grid = new Map(), edges = [];
  const nodeAt = (lat, lng) => {
    const gy = Math.round(lat * MPD_LAT / 2), gx = Math.round(lng * mPerDegLng(lat) / 2);
    for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
      const list = grid.get((gy + dy) + ':' + (gx + dx)); if (!list) continue;
      for (const idx of list) { const n = nodes[idx]; if (distMeters(lat, lng, n.lat, n.lng) <= 2) return idx; }
    }
    const idx = nodes.length, key = gy + ':' + gx;
    nodes.push({ lat, lng, edges: [] });
    if (!grid.has(key)) grid.set(key, []);
    grid.get(key).push(idx);
    return idx;
  };
  const link = (na, nb, line, seg, t0, t1) => {
    if (na === nb) return;
    const len = Math.abs(t1 - t0) * distMeters(line[seg][0], line[seg][1], line[seg + 1][0], line[seg + 1][1]);
    if (!(len > 0.15)) return;
    const idx = edges.push({ a: na, b: nb, line, seg, t0, t1, len }) - 1;
    nodes[na].edges.push(idx); nodes[nb].edges.push(idx);
  };
  lines.forEach(line => { for (const p of line) nodeAt(p[0], p[1]); });
  for (let i = 0; i < lines.length; i++) for (let j = i + 1; j < lines.length; j++) {
    const A = lines[i], B = lines[j];
    for (let p = 1; p < A.length; p++) for (let q = 1; q < B.length; q++) {
      const hit = segCrossPoint(A[p - 1], A[p], B[q - 1], B[q]);
      if (hit) nodeAt(hit[0], hit[1]);
    }
  }
  const cutsByLine = new Map();
  for (const line of lines) {
    const cuts = [], snapshot = nodes.slice();
    let acc = 0;
    for (let s = 0; s < line.length - 1; s++) {
      const a = line[s], b = line[s + 1], len = distMeters(a[0], a[1], b[0], b[1]) || 1;
      cuts.push({ seg: s, t: 0, node: nodeAt(a[0], a[1]), pos: acc });
      for (const n of snapshot) {
        if (distMeters(n.lat, n.lng, a[0], a[1]) > len + PED_SNAP_M) continue;
        const pr = projOnSegLL([n.lat, n.lng], a, b);
        if (distMeters(n.lat, n.lng, pr[0], pr[1]) > PED_SNAP_M) continue;
        const t = distMeters(a[0], a[1], pr[0], pr[1]) / len;
        if (t < 1e-3 || t > 1 - 1e-3) continue;
        cuts.push({ seg: s, t, node: nodeAt(pr[0], pr[1]), pos: acc + t * len });
      }
      acc += len;
      if (s === line.length - 2) cuts.push({ seg: s, t: 1, node: nodeAt(b[0], b[1]), pos: acc });
    }
    cuts.sort((p, q) => p.pos - q.pos);
    const uniq = [];
    for (const c of cuts) if (!uniq.length || c.pos - uniq[uniq.length - 1].pos > 0.2) uniq.push(c);
    for (let k = 1; k < uniq.length; k++) { const p = uniq[k - 1], q = uniq[k]; if (p.seg === q.seg) link(p.node, q.node, line, p.seg, p.t, q.t); }
    cutsByLine.set(line, uniq);
  }
  return { nodes, edges, cutsByLine };
}
function pedRouteFromTo(from, to) {                          // маршрут по сети: from/to = {line, seg, t}
  if (!from || !to || !from.line || !to.line) return null;
  if (from.line === to.line) return lineSteps(from.line, linePosOf(from.line, from.seg, from.t), linePosOf(to.line, to.seg, to.t));
  const net = sim.pedNet; if (!net) return null;
  const cutsA = net.cutsByLine.get(from.line), cutsB = net.cutsByLine.get(to.line);
  if (!cutsA || !cutsB || !cutsA.length || !cutsB.length) return null;
  const posA = linePosOf(from.line, from.seg, from.t), posB = linePosOf(to.line, to.seg, to.t);
  const targets = new Map();
  for (const c of cutsB) { const d = Math.abs(c.pos - posB); if (!targets.has(c.node) || targets.get(c.node) > d) targets.set(c.node, d); }
  const best = new Map(), prev = new Map(), heap = [];
  const pushH = (d, node) => {
    heap.push([d, node]);
    let i = heap.length - 1;
    while (i > 0) { const p = (i - 1) >> 1; if (heap[p][0] <= heap[i][0]) break; const tmp = heap[p]; heap[p] = heap[i]; heap[i] = tmp; i = p; }
  };
  const popH = () => {
    const top = heap[0], last = heap.pop();
    if (heap.length) {
      heap[0] = last;
      let i = 0;
      for (;;) {
        const l = i * 2 + 1, r = l + 1; let m = i;
        if (l < heap.length && heap[l][0] < heap[m][0]) m = l;
        if (r < heap.length && heap[r][0] < heap[m][0]) m = r;
        if (m === i) break;
        const tmp = heap[m]; heap[m] = heap[i]; heap[i] = tmp; i = m;
      }
    }
    return top;
  };
  for (const c of cutsA) { const d = Math.abs(c.pos - posA); if (d < (best.get(c.node) ?? Infinity)) { best.set(c.node, d); prev.set(c.node, null); pushH(d, c.node); } }
  let reached = -1;
  while (heap.length) {
    const [d, node] = popH();
    if (d > (best.get(node) ?? Infinity) + 1e-6) continue;
    if (targets.has(node)) { reached = node; break; }
    for (const ei of net.nodes[node].edges) {
      const e = net.edges[ei], other = e.a === node ? e.b : e.a, nd = d + e.len;
      if (nd < (best.get(other) ?? Infinity)) { best.set(other, nd); prev.set(other, { from: node, edge: ei }); pushH(nd, other); }
    }
  }
  if (reached < 0) return null;
  const chain = []; let cur = reached;
  while (prev.get(cur)) { chain.push({ edge: prev.get(cur).edge, from: prev.get(cur).from, to: cur }); cur = prev.get(cur).from; }
  chain.reverse();
  const steps = [];
  const cutA = cutsA.find(c => c.node === cur);
  const startPos = cutA ? cutA.pos : posA;
  steps.push(...lineSteps(from.line, posA, startPos));
  for (const item of chain) {
    const e = net.edges[item.edge];
    steps.push(e.a === item.from ? { line: e.line, seg: e.seg, t0: e.t0, t1: e.t1 } : { line: e.line, seg: e.seg, t0: e.t1, t1: e.t0 });
  }
  const cutB = cutsB.find(c => c.node === reached);
  const endPos = cutB ? cutB.pos : posB;
  steps.push(...lineSteps(to.line, endPos, posB));
  return steps;
}
function routeStepBegin(p) {                                // встать на текущий шаг маршрута
  const st = p.route && p.route[p.routeIdx];
  if (!st) return false;
  p.line = st.line; p.seg = st.seg; p.t = st.t0; p.fwd = st.t1 > st.t0; p.stepEnd = st.t1;
  return true;
}
function pedHere(cit) {                                     // текущая позиция жителя как точка сети
  if (!cit.line || cit.line.length < 2 || !cit.line[cit.seg + 1]) return null;
  return { line: cit.line, seg: cit.seg, t: Math.max(0, Math.min(1, cit.t)) };
}
function citRouteTo(cit, target) {                          // маршрут по сети до точки target
  const here = pedHere(cit);
  if (!here || !target || !target.line) return false;
  const steps = pedRouteFromTo(here, target);
  if (!steps || !steps.length) { cit.route = null; cit.routeIdx = 0; return false; }
  cit.route = steps; cit.routeIdx = 0;
  return routeStepBegin(cit);
}
function trainRouteFor(cit, targetPoint, goal) {       // маршрут поездом: если цель далеко и станции соединены ЖД
  if (!sim.transitStations?.length || !sim.railLines?.length) return null;
  const here = pedHere(cit); if (!here) return null;
  const start = lerpPos(here.line, here.seg, here.t), goalDist = distMeters(start[0], start[1], goal ? goal[0] : targetPoint[0], goal ? goal[1] : targetPoint[1]);
  if (goalDist < 350) return null;                     // близко — незачем ехать
  const stations = sim.transitStations.map(station => ({ station, access: sim.stationAccess.get(station) })).filter(x => x.access);
  if (stations.length < 2) return null;
  // компонента ЖД, в которой лежит станция (по её ближайшему рельсу)
  const componentOf = station => { const np = nearestRailPointForStation(station); if (!np) return null; return railComponentLines(np.line); };
  const entries = stations.map(({ station, access }) => ({ station, access, comp: componentOf(station) }));
  // ближайшая станция к жителю и к цели
  let entryA = null, entryB = null, bestA = Infinity, bestB = Infinity;
  for (const e of entries) {
    const dA = distMeters(start[0], start[1], e.access.networkPoint[0], e.access.networkPoint[1]);
    const dB = distMeters(goal ? goal[0] : targetPoint[0], goal ? goal[1] : targetPoint[1], e.access.networkPoint[0], e.access.networkPoint[1]);
    if (dA < bestA) { bestA = dA; entryA = e; }
    if (dB < bestB) { bestB = dB; entryB = e; }
  }
  if (!entryA || !entryB || entryA.station === entryB.station) return null;
  if (!entryA.comp || !entryB.comp || !entryA.comp.has(nearestRailPointForStation(entryB.station)?.line)) return null;   // станции не соединены ЖД
  const walkToA = bestA, walkFromB = bestB, railDist = roadLen(nearestRailPointForStation(entryA.station).line);
  if (walkToA + walkFromB + 150 > goalDist) return null;   // поездом не выгоднее
  return { entryA, entryB };
}
function assignDest(cit, options = {}) {                        // выбрать здание или станцию-цель на пешеходной сети
  cit.transit = null; cit.waitingAtStation = null; cit.waitSlot = null; cit.dest = null; cit.goal = null;
  cit.route = null; cit.routeIdx = 0;
  if (!sim.pedLines.length) { cit.status = 'гуляет'; return; }
  if (!options.avoidTransit && sim.transitStations?.length && Math.random() < .18) {
    const current = cit.line && cit.line[cit.seg + 1] ? lerpPos(cit.line, cit.seg, cit.t) : null;
    const candidates = sim.transitStations.map(station => ({ station, access: sim.stationAccess.get(station) }))
      .filter(item => item.access && (!current || distMeters(current[0], current[1], item.access.stationPoint[0], item.access.stationPoint[1]) > 20))
      .sort((a, b) => current ? distMeters(current[0], current[1], a.access.stationPoint[0], a.access.stationPoint[1]) - distMeters(current[0], current[1], b.access.stationPoint[0], b.access.stationPoint[1]) : 0)
      .slice(0, 4);
    for (let i = candidates.length - 1; i > 0; i--) { const k = randInt(i + 1); const tmp = candidates[i]; candidates[i] = candidates[k]; candidates[k] = tmp; }   // случайный порядок — идём к разным станциям
    for (const { station, access } of candidates) {
      if (!citRouteTo(cit, { line: access.networkLine, seg: access.segment, t: access.t })) continue;
      cit.dest = { type: 'station', name: station.name || 'станция' }; cit.goal = access.networkPoint;
      cit.transit = { state: 'toStation', stationKey: stationSimKey(station) };
      cit.status = `идёт на станцию ${station.name || ''}`.trim();
      return;
    }
  }
  const builds = state.buildings.filter(b => b.type !== 'tree' && isFinite(b.lat) && isFinite(b.lng));
  if (!builds.length) { cit.status = 'гуляет'; return; }
  let b = null, kind = '';
  if (cit.employed && cit.work) {                 // занятой житель ходит по маршруту дом ↔ работа
    const toWork = !cit.atWork;
    b = toWork ? cit.work : (cit.home || cit.work);
    kind = toWork ? 'work' : 'home';
  } else {
    b = builds[randInt(builds.length)];
    kind = b === cit.home ? 'home' : '';
  }
  let np = pedNearestPoint(doorEntry(b));          // идём ко входу дома, а не к его центру
  if (np && distMeters(b.lat, b.lng, np.pos[0], np.pos[1]) > 80) np = null;   // здание далеко от сети — не годится в цель
  if (!kind && !np) {                             // случайная цель вне сети — ищем достижимую
    for (let k = 0; k < 5 && !np; k++) {
      b = builds[randInt(builds.length)];
      np = pedNearestPoint(doorEntry(b));
      if (np && distMeters(b.lat, b.lng, np.pos[0], np.pos[1]) > 80) np = null;
    }
  }
  const g = np ? np.pos : [b.lat, b.lng];
  if (!isFinite(g[0]) || !isFinite(g[1])) { cit.dest = null; cit.goal = null; cit.status = 'гуляет'; return; }   // защита от битых координат
  // поезд в маршруте: цель далеко и достижима ЖД — едем поездом
  const viaTrain = trainRouteFor(cit, doorEntry(b), g);
  if (viaTrain && !options.avoidTransit) {
    const toEntry = viaTrain.entryA.access.networkPoint;
    if (citRouteTo(cit, { line: viaTrain.entryA.access.networkLine, seg: viaTrain.entryA.access.segment, t: viaTrain.entryA.access.t })) {
      cit.dest = { type: 'station', name: viaTrain.entryA.station.name || 'станция' };
      cit.goal = toEntry;
      cit.transit = { state: 'toStation', stationKey: stationSimKey(viaTrain.entryA.station), requestedDestination: { type: 'station', stationKey: stationSimKey(viaTrain.entryB.station), name: viaTrain.entryB.station.name || 'станция', finalGoal: g, finalBuilding: b, destKind: kind } };
      cit.status = `едет поездом до станции ${viaTrain.entryB.station.name || ''}`.trim();
      return;
    }
  }
  cit.dest = b; cit.goal = g; cit.destKind = kind;
  cit.status = kind === 'work' ? 'идёт на работу' : kind === 'home' ? 'идёт домой' : 'идёт ' + (b.type === 'shop' ? 'в магазин' : 'к дому');
  if (np) citRouteTo(cit, { line: np.line, seg: np.seg, t: np.t });   // настоящий маршрут по пешеходной сети
  else orientToGoal(cit);                                        // цели вне сети — прежняя логика
}
function orientToGoal(cit) {                                   // выбрать направление по текущей линии, что ближе к цели
  if (!cit.goal || !cit.line || !cit.line[cit.seg + 1]) return;
  const cur = lerpPos(cit.line, cit.seg, cit.t), ah = lerpPos(cit.line, cit.seg, Math.min(1, cit.t + 0.12));
  cit.fwd = distMeters(ah[0], ah[1], cit.goal[0], cit.goal[1]) <= distMeters(cur[0], cur[1], cit.goal[0], cit.goal[1]);
}
function lerpPos(line, seg, t) { const a = line[seg], b = line[seg + 1]; t = Math.max(0, Math.min(1, t)); return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]; }
function stationQueuePosition(station, slot = 0) {
  const g = stationGeometry(station), half = STATION_PLATFORM_LEN / 2 - 3, side = g.platformSide || (station.side == null ? 1 : station.side);
  // люди вдоль платформы: колонка (столбец) — вдоль пути, ряд — вглубь платформы от края у путей
  const columns = 32, column = slot % columns, row = Math.floor(slot / columns);
  const along = -half + (half * 2) * (column + .5) / columns, inM = (g.platformInner ?? STATION_RAIL_GAP) + 1 + row * 1.05;
  return offset(g.point[0], g.point[1], g.e * along - g.n * inM * side, g.n * along + g.e * inM * side);
}
function trainAtStation(station) {                 // поезд, который сейчас стоит у станции (dwell)
  return sim.trains.find(t => !t.dead && t.stationKey === station && t.dwell > 0) || null;
}
function trainDoorPos(train, slot, side = 1, station = null) {      // позиция у дверей вагона (край платформы у поезда)
  const wagons = train.wagons || []; if (!wagons.length) return null;
  const w = wagons[slot % wagons.length]; if (!w || !w.pos) return null;
  const e = Math.cos(w.angle), n = Math.sin(w.angle), off = STATION_RAIL_GAP + 1.4;
  let dir = side;
  if (station) {                                        // сторона дверей — всегда к платформе, независимо от направления
    const g = stationGeometry(station);
    const de = (g.platformMid[1] - w.pos[1]) * mPerDegLng(w.pos[0]), dn = (g.platformMid[0] - w.pos[0]) * MPD_LAT;
    dir = (de * (-n) + dn * e) >= 0 ? 1 : -1;
  }
  return offset(w.pos[0], w.pos[1], -n * off * dir, e * off * dir);
}
function pedestrianPosition(p) {
  if (!p || p.dead || p.transit?.state === 'onTrain') return null;
  if (p._board) { const f = Math.max(0, Math.min(1, p._board.t || 0)), from = p._board.from, to = p._board.to; if (from && to) return [from[0] + (to[0] - from[0]) * f, from[1] + (to[1] - from[1]) * f]; }
  if (p.waitingAtStation) { const pos = stationQueuePosition(p.waitingAtStation, p.waitSlot || 0); return [pos[0], pos[1]]; }
  if (!p.line || !p.line[p.seg + 1]) return null;
  return smoothLinePoint(p.line, p.seg, p.t) || lerpPos(p.line, p.seg, p.t);
}
function segBear(line, seg, fwd) { const a = line[seg], b = line[seg + 1]; let ang = Math.atan2((b[0] - a[0]) * MPD_LAT, (b[1] - a[1]) * mPerDegLng(a[0])); return fwd ? ang : ang + Math.PI; }
function trafficSpawnTooClose(c, other) {
  const a = smoothCarPose(c), b = smoothCarPose(other); if (!a || !b) return false;
  const lat = (a.pos[0] + b.pos[0]) / 2, de = (b.pos[1] - a.pos[1]) * mPerDegLng(lat), dn = (b.pos[0] - a.pos[0]) * MPD_LAT;
  if (c.line === other.line && c.fwd === other.fwd && lineMeta(c.line).oneWay && c.lane !== other.lane) {
    const side = Math.abs(-de * Math.sin(a.angle) + dn * Math.cos(a.angle));
    if (side > laneOffset(c.line) * 1.2) return false;
  }
  if (c.line === other.line && c.fwd !== other.fwd) {
    const side = Math.abs(-de * Math.sin(a.angle) + dn * Math.cos(a.angle));
    if (side > (vehicleWidth(c) + vehicleWidth(other)) / 2 + .25) return false;
  }
  return Math.hypot(de, dn) < (vehicleLength(c) + vehicleLength(other)) / 2 + 1.1;
}
const JUNCTION_CELL = .0001; // spatial bucket for a ~10 m intersection zone
function junctionKeyFor(point) { return point ? `${point[0].toFixed(4)}:${point[1].toFixed(4)}` : null; }
function junctionCellKey(point, dy = 0, dx = 0) {
  if (!point) return null;
  return `${Math.floor(point[0] / JUNCTION_CELL) + dy}:${Math.floor(point[1] / JUNCTION_CELL) + dx}`;
}
function junctionIndexAdd(index, c, turn) {
  const key = junctionCellKey(turn && turn.junctionPoint); if (!key) return;
  turn._junctionCellKey = key;
  const list = index.get(key) || [];
  if (!list.includes(c)) list.push(c);
  index.set(key, list);
}
function junctionIndexRemove(index, c, turn) {
  const key = (turn && turn._junctionCellKey) || junctionCellKey(turn && turn.junctionPoint); if (!key) return;
  const list = (index.get(key) || []).filter(other => other !== c);
  if (list.length) index.set(key, list); else index.delete(key);
  return key;
}
function junctionCarsNear(index, turn) {
  const point = turn && turn.junctionPoint; if (!index || !point) return [];
  const out = [], seen = new Set();
  for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
    for (const c of (index.get(junctionCellKey(point, dy, dx)) || [])) if (!seen.has(c)) { seen.add(c); out.push(c); }
  }
  return out;
}
function junctionHasCarsNear(index, turn) {
  const point = turn && turn.junctionPoint; if (!index || !point) return false;
  for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
    if ((index.get(junctionCellKey(point, dy, dx)) || []).length > 0) return true;
  }
  return false;
}
function buildTrafficIndex() {
  const lanes = new Map(), lineCounts = new Map(), activeJunctions = new Map(), requestedJunctions = new Map(), activeSpatial = new Map(), requestedSpatial = new Map();
  for (const c of sim.cars) {
    c._trafficLeader = null;
    if (!c.line || c.line.length < 2) continue;
    const pose = smoothCarPose(c);
    c._pos = pose ? pose.pos : null; c._ang = pose ? pose.angle : 0;
    c._tr = lineProgress(c.line, c.seg, c.t, c.fwd);
    lineCounts.set(c.line, (lineCounts.get(c.line) || 0) + 1);
    if (!lanes.has(c.line)) lanes.set(c.line, {});
    const laneKey = trafficLaneKey(c.line, c.fwd, c.lane);
    if (!lanes.get(c.line)[laneKey]) lanes.get(c.line)[laneKey] = [];
    lanes.get(c.line)[laneKey].push(c);
    if (c.turn && c.turn.junctionKey) {
      if (!activeJunctions.has(c.turn.junctionKey)) activeJunctions.set(c.turn.junctionKey, []);
      activeJunctions.get(c.turn.junctionKey).push(c);
      junctionIndexAdd(activeSpatial, c, c.turn);
    }
    if (c.nextTurn && c.nextTurn.junctionKey) {
      if (!requestedJunctions.has(c.nextTurn.junctionKey)) requestedJunctions.set(c.nextTurn.junctionKey, []);
      requestedJunctions.get(c.nextTurn.junctionKey).push(c);
      junctionIndexAdd(requestedSpatial, c, c.nextTurn);
    }
  }
  for (const dirs of lanes.values()) for (const list of Object.values(dirs)) {
    list.sort((a, b) => b._tr - a._tr);
    for (let i = 1; i < list.length; i++) list[i]._trafficLeader = list[i - 1];
    if (list[0]) list[0]._trafficLeader = null;
  }
  sim._trafficLanes = lanes;
  sim._trafficLineCounts = lineCounts;
  sim._junctionTraffic = activeJunctions;
  sim._junctionRequests = requestedJunctions;
  sim._junctionTrafficSpatial = activeSpatial;
  sim._junctionRequestsSpatial = requestedSpatial;
  sim._junctionTrafficSpatialWinners = junctionSpatialWinners(activeSpatial);
  sim._junctionRequestsSpatialWinners = junctionSpatialWinners(requestedSpatial);
}
function trafficPriorityWinner(a, b) {
  if (a.line === b.line && trafficLaneKey(a.line, a.fwd, a.lane) === trafficLaneKey(b.line, b.fwd, b.lane) && !a.turn && !b.turn) {
    const ap = lineProgress(a.line, a.seg, a.t, a.fwd), bp = lineProgress(b.line, b.seg, b.t, b.fwd);
    if (Math.abs(ap - bp) > .05) return ap > bp ? a : b;
  }
  return (a.id || 0) <= (b.id || 0) ? a : b;
}
function junctionSpatialWinners(index) {
  const winners = new Map();
  for (const [key, list] of index) {
    let winner = null;
    for (const c of list) if (!winner || trafficPriorityWinner(c, winner) === c) winner = c;
    if (winner) winners.set(key, winner);
  }
  return winners;
}
function junctionSpatialWinnerAdd(winners, c, turn) {
  const key = junctionCellKey(turn && turn.junctionPoint); if (!winners || !key) return;
  const current = winners.get(key);
  if (!current || trafficPriorityWinner(c, current) === c) winners.set(key, c);
}
function junctionSpatialWinnerRemove(index, winners, c, turn) {
  const key = (turn && turn._junctionCellKey) || junctionCellKey(turn && turn.junctionPoint); if (!winners || !key) return;
  if (winners.get(key) !== c) return;
  const list = index?.get(key) || [];
  let winner = null;
  for (const other of list) if (!winner || trafficPriorityWinner(other, winner) === other) winner = other;
  if (winner) winners.set(key, winner); else winners.delete(key);
}
function junctionWinnersNear(winners, turn) {
  const point = turn && turn.junctionPoint; if (!winners || !point) return [];
  const out = [], seen = new Set();
  for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
    const c = winners.get(junctionCellKey(point, dy, dx));
    if (c && !seen.has(c)) { seen.add(c); out.push(c); }
  }
  return out;
}
function trafficLineLoad(line) { return sim._trafficLineCounts?.get(line) || 0; }
// Машина впереди по ходу (в т.ч. во время поворота, когда полосной лидер не
// работает). Даёт зазор до чужого кузова в коридоре шириной с мою машину.
function aheadObstacle(c) {
  if (!c._pos) return null;
  const fx = Math.cos(c._ang || 0), fy = Math.sin(c._ang || 0), myLen = vehicleLength(c), myW = vehicleWidth(c);
  let best = null;
  for (const o of sim.cars) {
    if (o === c || o.dead || !o._pos) continue;
    const dE = (o._pos[1] - c._pos[1]) * mPerDegLng(c._pos[0]), dN = (o._pos[0] - c._pos[0]) * MPD_LAT;
    if (dE > 22 || dE < -22 || dN > 22 || dN < -22) continue;
    const along = dE * fx + dN * fy;
    if (along <= 0) continue;
    const lateral = Math.abs(-dE * fy + dN * fx);
    if (lateral > (vehicleWidth(o) + myW) / 2 + .35) continue;
    // Поперечный поток — не мой лидер: иначе кольцо встаёт перед машиной,
    // ждущей въезда, и оба ждут друг друга.
    if (Math.abs(angleDelta(o._ang || 0, c._ang || 0)) > Math.PI / 3) continue;
    const gap = along - (myLen + vehicleLength(o)) / 2 - .35;
    if (!best || gap < best.gap) best = { gap, speed: o.v || 0, other: o };
  }
  return best;
}
function chooseTrafficOption(options) {
  if (!options.length) return null;
  let minLoad = Infinity;
  for (const option of options) minLoad = Math.min(minLoad, trafficLineLoad(option.line));
  const pool = options.filter(option => trafficLineLoad(option.line) <= minLoad + 1.25);
  return pool[randInt(pool.length)];
}
function trafficConflict(c) {
  const turn = c.nextTurn; if (!turn || !turn.junctionKey) return null;
  const contenders = new Set([
    ...junctionWinnersNear(sim._junctionRequestsSpatialWinners, turn),
    ...junctionWinnersNear(sim._junctionTrafficSpatialWinners, turn)
  ]);
  for (const other of contenders) {
    if (other !== c && trafficPriorityWinner(c, other) !== c) return { other, gap: 0, yielding: true, emergency: false };
  }
  return null;
}
function addJunctionCar(c, turn) {
  const key = turn && turn.junctionKey; if (!key) return;
  if (!sim._junctionTraffic) sim._junctionTraffic = new Map();
  const active = sim._junctionTraffic.get(key) || [];
  if (!active.includes(c)) active.push(c);
  sim._junctionTraffic.set(key, active);
  if (sim._junctionRequests) {
    const requested = (sim._junctionRequests.get(key) || []).filter(other => other !== c);
    if (requested.length) sim._junctionRequests.set(key, requested); else sim._junctionRequests.delete(key);
  }
  if (!sim._junctionTrafficSpatial) sim._junctionTrafficSpatial = new Map();
  if (!sim._junctionTrafficSpatialWinners) sim._junctionTrafficSpatialWinners = junctionSpatialWinners(sim._junctionTrafficSpatial);
  junctionIndexAdd(sim._junctionTrafficSpatial, c, turn);
  junctionSpatialWinnerAdd(sim._junctionTrafficSpatialWinners, c, turn);
  if (sim._junctionRequestsSpatial) {
    const removedKey = junctionIndexRemove(sim._junctionRequestsSpatial, c, turn);
    junctionSpatialWinnerRemove(sim._junctionRequestsSpatial, sim._junctionRequestsSpatialWinners, c, turn);
    if (removedKey && sim._junctionRequestsSpatialWinners && sim._junctionRequestsSpatialWinners.get(removedKey) === c) sim._junctionRequestsSpatialWinners.delete(removedKey);
  }
}
function removeJunctionCar(c, turn) {
  const key = turn && turn.junctionKey; if (!key || !sim._junctionTraffic) return;
  const active = (sim._junctionTraffic.get(key) || []).filter(other => other !== c);
  if (active.length) sim._junctionTraffic.set(key, active); else sim._junctionTraffic.delete(key);
  if (sim._junctionTrafficSpatial) {
    const removedKey = junctionIndexRemove(sim._junctionTrafficSpatial, c, turn);
    junctionSpatialWinnerRemove(sim._junctionTrafficSpatial, sim._junctionTrafficSpatialWinners, c, turn);
    if (removedKey && sim._junctionTrafficSpatialWinners && sim._junctionTrafficSpatialWinners.get(removedKey) === c) sim._junctionTrafficSpatialWinners.delete(removedKey);
  }
}
function addJunctionRequest(c, turn) {
  const key = turn && turn.junctionKey; if (!key) return;
  if (!sim._junctionRequests) sim._junctionRequests = new Map();
  const requested = sim._junctionRequests.get(key) || [];
  if (!requested.includes(c)) requested.push(c);
  sim._junctionRequests.set(key, requested);
  if (!sim._junctionRequestsSpatial) sim._junctionRequestsSpatial = new Map();
  if (!sim._junctionRequestsSpatialWinners) sim._junctionRequestsSpatialWinners = junctionSpatialWinners(sim._junctionRequestsSpatial);
  junctionIndexAdd(sim._junctionRequestsSpatial, c, turn);
  junctionSpatialWinnerAdd(sim._junctionRequestsSpatialWinners, c, turn);
}
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
function geoBearing(a, b) { return Math.atan2((b[0] - a[0]) * MPD_LAT, (b[1] - a[1]) * mPerDegLng(a[0])); }
function laneOffsetVector(line, seg, fwd, lane = 0) {
  const v = segmentVector(line, seg, true), side = lineMeta(line).oneWay ? (lane === 1 ? -1 : 1) : (fwd ? 1 : -1), gap = laneOffset(line) * side;
  return { e: v.n * gap, n: -v.e * gap };
}
function lineDistanceToEnd(line, seg, t, fwd) {
  let s = seg, u = t, total = 0, guard = 0;
  while (s >= 0 && s < line.length - 1 && guard++ < line.length + 3) {
    const v = segmentVector(line, s, true); total += fwd ? (1 - u) * v.len : u * v.len;
    if (fwd) { if (s >= line.length - 2) break; s++; u = 0; }
    else { if (s <= 0) break; s--; u = 1; }
  }
  return total;
}
function lineProgress(line, seg, t, fwd) {
  const cum = [0];
  for (let i = 1; i < line.length; i++) cum.push(cum[i - 1] + distMeters(line[i - 1][0], line[i - 1][1], line[i][0], line[i][1]));
  const along = cum[seg] + Math.max(0, Math.min(1, t)) * (cum[seg + 1] - cum[seg]);
  return fwd ? along : cum[cum.length - 1] - along;
}
function vehicleTurnBlocked(c, turn) {
  if (!turn || !turn.end || !turn.end.line) return false;
  if (turn.junctionKey) {
    if (junctionHasCarsNear(sim._junctionTrafficSpatial, turn)) return true;
  }
  const end = turn.end, endProgress = lineProgress(end.line, end.seg, end.t, end.fwd);
  const clearance = Math.min(12, Math.max(5.5, turn.length * .65 + (c.v || 0) * .28 + vehicleLength(c) * .45));
  let blocked = false;
  const lane = sim._trafficLanes?.get(end.line)?.[trafficLaneKey(end.line, end.fwd, end.lane)] || [];
  for (const other of lane) {
    if (other === c || other.turn) continue;
    const progress = lineProgress(other.line, other.seg, other.t, other.fwd), gap = progress - endProgress - (vehicleLength(c) + vehicleLength(other)) / 2 - .8;
    if (progress > endProgress && gap < clearance && (other.v || 0) < Math.max(1.8, (c.v || 0) * .48)) { blocked = true; break; }
  }
  return blocked;
}
function junctionOptions(c, endpoint, returnAll = false) {
  const options = [], r = c.line, incoming = segmentVector(r, c.seg, c.fwd), incomingAngle = Math.atan2(incoming.n, incoming.e), tol = Math.max(4.5, LINE_M.road * .9);
  for (const line of sim.driveLines) {
    if (line === r) {
      if (!lineIsClosed(line)) continue;
      // шов кольца: продолжение движения по той же линии с её начала
      const raw = segmentVector(line, 0, true), loopBend = Math.abs(angleDelta(Math.atan2(raw.n, raw.e), incomingAngle));
      options.push({ line, seg: 0, t: 0, fwd: true, point: [line[0][0], line[0][1]], bend: loopBend, distance: 0, loop: true });
      continue;
    }
    if (line.length < 2) continue;
    for (let i = 1; i < line.length; i++) {
      const hit = projOnSegLL(endpoint, line[i - 1], line[i]), distance = distMeters(endpoint[0], endpoint[1], hit[0], hit[1]);
      if (distance > tol) continue;
      const raw = segmentVector(line, i - 1, true), segLen = raw.len, e = (hit[1] - line[i - 1][1]) * mPerDegLng(line[i - 1][0]), n = (hit[0] - line[i - 1][0]) * MPD_LAT;
      const t = Math.max(0, Math.min(1, Math.hypot(e, n) / segLen));
      const directions = lineMeta(line).oneWay ? [true] : [true, false];
      for (const fwd of directions) {
        const available = fwd ? (1 - t) * segLen : t * segLen;
        if (available < .45) continue; // the adjacent segment will offer the valid direction at an exact vertex
        const out = segmentVector(line, i - 1, fwd), bend = Math.abs(angleDelta(Math.atan2(out.n, out.e), incomingAngle));
        options.push({ line, seg: i - 1, t, fwd, point: hit, bend, distance });
      }
    }
  }
  if (!options.length) return null;
  if (returnAll) return options;
  // Never choose a near-180 degree branch while a real turn is available.
  const natural = options.filter(o => o.bend < Math.PI * .84), pool = natural.length ? natural : options;
  const bestBend = Math.min(...pool.map(o => o.bend)), preferred = pool.filter(o => o.bend <= bestBend + .62);
  const alleyOptions = pool.filter(o => state.alleys.includes(o.line));
  const roadOptions = pool.filter(o => !state.alleys.includes(o.line));
  if (alleyOptions.length) {
    const alleyLoad = Math.min(...alleyOptions.map(o => trafficLineLoad(o.line))), roadLoad = roadOptions.length ? Math.min(...roadOptions.map(o => trafficLineLoad(o.line))) : Infinity;
    const alleyChance = c.type === 'truck' ? .78 : .66;
    if (!roadOptions.length || alleyLoad + 1.25 < roadLoad || Math.random() < alleyChance) return chooseTrafficOption(alleyOptions);
  }
  return chooseTrafficOption(preferred);
}
function routeEndpoint(line, fwd) { return fwd ? line[line.length - 1] : line[0]; }
function randomRouteOption(c, options, avoidLine = null) {
  if (!options || !options.length) return null;
  let pool = options.filter(o => o.line !== avoidLine);
  if (!pool.length) pool = options;
  const weighted = pool.map(option => {
    const load = trafficLineLoad(option.line), bendWeight = option.bend > Math.PI * .84 ? .08 : option.bend > 1.3 ? .45 : 1;
    const alleyWeight = state.alleys.includes(option.line) ? (c.type === 'truck' ? 1.8 : 1.35) : 1;
    return { option, weight: Math.max(.04, bendWeight * alleyWeight / (1 + load * .28)) };
  });
  const total = weighted.reduce((sum, item) => sum + item.weight, 0);
  let pick = Math.random() * total;
  for (const item of weighted) { pick -= item.weight; if (pick <= 0) return item.option; }
  return weighted[weighted.length - 1].option;
}
function appendRandomRouteTail(c, firstOption) {
  let previousLine = c.line, currentLine = firstOption.line, currentFwd = firstOption.fwd;
  const hops = 3 + randInt(6);
  for (let hop = 0; hop < hops; hop++) {
    const fake = { line: currentLine, seg: currentFwd ? currentLine.length - 2 : 0, t: currentFwd ? 1 : 0, fwd: currentFwd, type: c.type };
    const options = junctionOptions(fake, routeEndpoint(currentLine, currentFwd), true);
    const next = randomRouteOption(fake, options, previousLine);
    if (!next) break;
    c.route.push({ line: next.line, fwd: next.fwd, point: next.point ? [next.point[0], next.point[1]] : null });
    previousLine = currentLine; currentLine = next.line; currentFwd = next.fwd;
  }
}
function queueRandomRoute(c, firstOption) {
  if (!firstOption) return;
  c.route = c.route || [];
  c.route.push({ line: firstOption.line, fwd: firstOption.fwd, point: firstOption.point ? [firstOption.point[0], firstOption.point[1]] : null });
  appendRandomRouteTail(c, firstOption);
}
function prepareRandomRoute(c) {
  c.route = [];
  const endpoint = routeEndpoint(c.line, c.fwd), options = junctionOptions(c, endpoint, true), first = randomRouteOption(c, options, c.line);
  if (first) queueRandomRoute(c, first);
}
function chooseCarRouteOption(c, endpoint) {
  const options = junctionOptions(c, endpoint, true);
  if (!options || !options.length) return null;
  let picked = null;
  const planned = c.route && c.route[0];
  if (planned) {
    const matches = options.filter(o => o.line === planned.line && o.fwd === planned.fwd);
    if (matches.length) {
      picked = planned.point
        ? matches.slice().sort((a, b) => distMeters(a.point[0], a.point[1], planned.point[0], planned.point[1]) - distMeters(b.point[0], b.point[1], planned.point[0], planned.point[1]))[0]
        : matches[0];
      c.route.shift();
    } else c.route = [];
  }
  if (!picked) {
    picked = randomRouteOption(c, options, c.line);
    if (picked) queueRandomRoute(c, picked);
  } else if (!c.route.length) appendRandomRouteTail(c, picked);
  return picked;
}
function buildVehicleTurn(c, candidate, endpoint, endState, outLead, isJunction = false) {
  const pose = smoothCarPose(c); if (!pose) return null;
  const endLane = endState.line === c.line ? (c.lane || 0) : (lineMeta(endState.line).oneWay ? randInt(2) : 0);
  const end = { ...endState, lane: endLane }, from = pose.pos, to = lineLanePoint(end.line, end.seg, end.t, end.fwd, end.lane); if (!to) return null;
  const oldOff = laneOffsetVector(c.line, c.seg, c.fwd, c.lane), newOff = laneOffsetVector(end.line, end.seg, end.fwd, end.lane);
  const center = candidate ? [(endpoint[0] + candidate.point[0]) / 2, (endpoint[1] + candidate.point[1]) / 2] : endpoint;
  const controlFactor = c.type === 'truck' ? .12 : .22;
  const control = offset(center[0], center[1], (oldOff.e + newOff.e) * controlFactor, (oldOff.n + newOff.n) * controlFactor);
  const curve = turnSamples(from, control, to), incoming = Math.atan2(segmentVector(c.line, c.seg, c.fwd).n, segmentVector(c.line, c.seg, c.fwd).e), outgoing = Math.atan2(segmentVector(endState.line, endState.seg, endState.fwd).n, segmentVector(endState.line, endState.seg, endState.fwd).e);
  const junctionPoint = isJunction && endpoint ? (candidate && candidate.point ? [candidate.point[0], candidate.point[1]] : [endpoint[0], endpoint[1]]) : null;
  return { ...curve, s: 0, end, limit: turnSpeedLimit(c, incoming, outgoing, curve.length), outLead, candidate, junctionPoint, junctionKey: junctionKeyFor(junctionPoint) };
}
function buildUTurn(c, endpoint) {
  if (lineMeta(c.line).oneWay) return null;
  const startSeg = c.fwd ? c.line.length - 2 : 0, startT = c.fwd ? 1 : 0, newFwd = !c.fwd;
  const lead = Math.min(Math.max(2.8, turnLead(c)), Math.max(1.5, segmentVector(c.line, startSeg, true).len * .45));
  const end = lineStateAfter(c.line, startSeg, startT, newFwd, lead), turn = buildVehicleTurn(c, null, endpoint, end, lead, true);
  if (turn) turn.limit = Math.min(turn.limit, Math.max(2.6, c.maxSpd * .45));
  return turn;
}
function buildNextVehicleTurn(c) {
  const r = c.line, last = r.length - 2;
  let next = null, endpoint;
  if (c.fwd && c.seg < last) { endpoint = r[c.seg + 1]; next = { line: r, seg: c.seg + 1, t: 0, fwd: true, point: endpoint }; }
  else if (!c.fwd && c.seg > 0) { endpoint = r[c.seg]; next = { line: r, seg: c.seg - 1, t: 1, fwd: false, point: endpoint }; }
  else {
    endpoint = c.fwd ? r[r.length - 1] : r[0];
    if (!lineIsClosed(r) && lineEndpointExit(r, c.fwd, 'road')) return null;
    const picked = chooseCarRouteOption(c, endpoint);
    if (picked) {
      const reach = lineDistanceToEnd(picked.line, picked.seg, picked.t, picked.fwd), lead = Math.min(turnLead(c), Math.max(1.2, reach * .42));
      const end = lineStateAfter(picked.line, picked.seg, picked.t, picked.fwd, lead);
      return buildVehicleTurn(c, picked, endpoint, end, lead, true);
    }
    return buildUTurn(c, endpoint);
  }
  const reach = lineDistanceToEnd(next.line, next.seg, next.t, next.fwd), lead = Math.min(turnLead(c), Math.max(1.2, reach * .42));
  const end = lineStateAfter(next.line, next.seg, next.t, next.fwd, lead);
  return buildVehicleTurn(c, null, endpoint, end, lead);
}
function finishVehicleTurn(c) {
  const tr = c.turn; if (!tr) return;
  removeJunctionCar(c, tr);
  Object.assign(c, tr.end); c.turn = null;
}
function updateTruckPhysics(c, dt) {
  if (c.type !== 'truck') return;
  const pose = smoothCarPose(c); if (!pose) return;
  if (!Number.isFinite(c.trailerAngle)) {
    const base = segmentVector(c.line, c.seg, c.fwd); c.trailerAngle = Math.atan2(base.n, base.e); return;
  }
  const diff = angleDelta(pose.angle, c.trailerAngle), followRate = Math.min(2.4, .18 + (c.v || 0) / Math.max(2.5, c.trailerWheelbase || 5.1));
  // The trailer follows the tractor with a delay instead of being rotated as
  // one rigid sprite. This also makes backing through a U-turn visibly tame.
  c.trailerAngle += Math.sin(diff) * followRate * dt;
  if (Math.abs(diff) < .002) c.trailerAngle = pose.angle;
}
function junction(c, atEnd) { c.turn = buildNextVehicleTurn(c); }
function stepCar(c, dt) {
  const r = c.line;
  if (!r || r.length < 2 || !r[c.seg] || !r[c.seg + 1]) { if (!sim.driveLines.length) { c.dead = true; return; } Object.assign(c, makeCar(sim.driveLines[randInt(sim.driveLines.length)])); return; }
  if (maybeParkCar(c, dt)) return;
  let left = Math.max(0, (c.v || 0) * dt), guard = 0;
  while (guard++ < 8) {
    if (c.turn) {
      const available = c.turn.length - c.turn.s, moved = Math.min(left, available); c.turn.s += moved; left -= moved;
      if (c.turn.s >= c.turn.length - 1e-4) { finishVehicleTurn(c); if (left <= 1e-5) break; continue; }
      break;
    }
    const line = c.line, raw = segmentVector(line, c.seg, true), available = c.fwd ? (1 - c.t) * raw.len : c.t * raw.len;
    const lead = turnLead(c);
    // Кольцо: съезд на примыкание, которое упирается в середину сегмента.
    if (!c.turn && (c.v || 0) >= .05 && lineIsClosed(line)) {
      const exitTurn = ringExitTurn(c);
      if (exitTurn) {
        c.nextTurn = null; c._junctionWaiting = false; c.route = [];
        c.turn = exitTurn; addJunctionCar(c, c.turn);
        c.v = Math.min(c.v, c.turn.limit || c.v);
        break;
      }
    }
    if (available > lead + 1e-4) {
      const moved = Math.min(left, available - lead); c.t += (c.fwd ? 1 : -1) * moved / raw.len; left -= moved;
      if (left <= 1e-5) break;
      continue;
    }
    if ((c.v || 0) < .05) break;
    const nextTurn = c.nextTurn || buildNextVehicleTurn(c);
    if (!nextTurn) { c.dead = true; break; }
    if (vehicleTurnBlocked(c, nextTurn)) {
      c.nextTurn = nextTurn;
      c._junctionWaiting = true;
      addJunctionRequest(c, nextTurn);
      break;
    }
    c.nextTurn = null;
    c._junctionWaiting = false;
    c.turn = nextTurn;
    addJunctionCar(c, c.turn);
    c.v = Math.min(c.v, c.turn.limit || c.v);
    if (left <= 1e-5) break;
  }
  updateTruckPhysics(c, dt);
}
const phaseGreenNS = () => Math.floor(sim.t / 5) % 2 === 0;   // фаза: зелёный С-Ю / В-З по 5 с
function roadCum(r) { const c = [0]; for (let i = 1; i < r.length; i++) c.push(c[i - 1] + distMeters(r[i - 1][0], r[i - 1][1], r[i][0], r[i][1])); return c; }
function computeCarSpeeds(dt) {
  buildTrafficIndex();
  for (const c of sim.cars) {
    const r = c.line;
    if (!r || r.length < 2) { c.v = 0; continue; }
    let leader = c.turn ? null : c._trafficLeader, frontGap = leader ? lineProgress(leader.line, leader.seg, leader.t, leader.fwd) - lineProgress(c.line, c.seg, c.t, c.fwd) - (vehicleLength(c) + vehicleLength(leader)) / 2 - .7 : Infinity;
    const v = c.v || 0, accel = c.accel || 9, brake = c.brake || 28;
    let target = c.spd;
    if (c.turn) target = Math.min(target, c.turn.limit || target);
    if (frontGap < Infinity) {
      const gap = frontGap, frontSpeed = leader ? (leader.v || 0) : 0;
      const closing = Math.max(0, (c.v || 0) - frontSpeed);
      const desiredGap = (c.type === 'truck' ? 3.1 : 2.2) + (c.type === 'truck' ? v * .72 : v * .52) + closing * .32;
      const followTarget = frontSpeed + (gap - desiredGap) * .72;
      const safeGap = Math.max(0, gap - .25), safeSpeed = Math.sqrt(Math.max(0, 2 * brake * safeGap));
      target = Math.min(target, Math.max(0, Math.min(c.spd, followTarget, safeSpeed)));
      if (gap < .05) target = 0;
    }
    // Тормозим перед любым кузовом впереди — и на повороте тоже, где
    // полосного лидера нет.
    const ahead = aheadObstacle(c);
    if (ahead) {
      const gap = Math.max(0, ahead.gap);
      // Уже наложились — медленно протискиваемся, иначе пара машин
      // замирает навсегда и собирает пробку за собой.
      if (gap < .15) target = Math.min(target, Math.max(.9, ahead.speed));
      else target = Math.min(target, Math.max(ahead.speed * .85, Math.sqrt(2 * brake * (gap - .2))));
    }
    const conflict = trafficConflict(c);
    if (conflict && conflict.yielding) {
      const gap = Math.max(0, conflict.gap);
      target = Math.min(target, gap > 0 ? Math.min(c.spd, gap / 1.35) : 0);
    }
    const waitingTurn = c.nextTurn && vehicleTurnBlocked(c, c.nextTurn);
    c._junctionWaiting = Boolean(waitingTurn);
    if (waitingTurn) {
      c._junctionWait = (c._junctionWait || 0) + dt;
      if (c._junctionWait > 7) { c.route = []; c.nextTurn = null; c._junctionWait = 0; c._junctionWaiting = false; }
      else target = 0;
    } else c._junctionWait = 0;
    if (carBlocked(c)) target = 0;
    const comfortBrake = Math.min(brake, (c.type === 'truck' ? 5.5 : 7) + v * .9);
    c._trafficTarget = target;
    c.v = target > v ? Math.min(target, v + accel * dt) : Math.max(target, v - comfortBrake * dt);
    if (c.v < 0) c.v = 0;
  }
}
function citizenJunction(p, atEnd) {              // на стыке свернуть В СТОРОНУ ЦЕЛИ (жадно), иначе — случайно
  const endpoint = atEnd ? p.line[p.line.length - 1] : p.line[0];
  if (exitNearPoint(endpoint, 'walk', 12)) { p.dead = true; return; }
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
function citizenArrive(p) {                                   // дошёл до цели
  if (p.transit?.state === 'toStation') {
    const station = stationBySimKey(p.transit.stationKey);
    if (station && setCitizenAtStation(p, station, false)) return;
    assignDest(p, { avoidTransit: true }); return;
  }
  p.route = null; p.routeIdx = 0;
  p.idle = 2 + Math.random() * 5;
  p.atWork = p.destKind === 'work';
  p.status = p.destKind === 'work' ? 'на работе'
    : p.destKind === 'home' ? 'дома'
    : 'на месте: ' + (p.dest && p.dest.type === 'shop' ? 'магазин' : 'дом');
  p.goal = null;
}
function stepPed(p, dt) {
  if (p._board) {                                       // посадка/высадка: идёт к двери или на платформу
    p._board.t += dt / p._board.dur;
    if (p._board.t >= 1) {
      const b = p._board; p._board = null;
      if (b.alight) {                                   // вышел — продолжить пешком (к цели или случайно)
        p.transit = null; p.waitingAtStation = null;
        p.line = b.station ? (sim.stationAccess.get(b.station)?.networkLine || null) : null;
        if (p.line) { const acc = sim.stationAccess.get(b.station); p.seg = acc.segment; p.t = acc.t; p.fwd = true;
          if (p._alightFinal?.finalGoal) { p.dest = p._alightFinal.finalBuilding || null; p.goal = p._alightFinal.finalGoal; p.destKind = p._alightFinal.destKind || ''; p.status = 'идёт к цели'; citRouteTo(p, { line: p.line, seg: p.seg, t: p.t }); delete p._alightFinal; }
          else { p.goal = null; p.status = 'вышел на станции'; assignDest(p, { avoidTransit: true }); }
        } else { assignDest(p, { avoidTransit: true }); }
      } else {                                          // сел — теперь пассажир поезда
        const train = b.train; if (train && !train.dead) {
          p.transit = { state: 'onTrain', originStationKey: b.station ? stationSimKey(b.station) : null, destination: b.requestedDestination || p.transit?.requestedDestination || passengerDestinationForTrain(train, b.station) || null };
          p.status = `едет поездом · ${p.transit.destination?.name || 'поезд'}`;
          train.passengers.push(p);
        } else { p.dead = true; }
      }
    }
    return;
  }
  if (p.transit?.state === 'waiting' || p.transit?.state === 'onTrain') return;
  if (p.idle > 0) { p.idle -= dt; if (p.idle <= 0) assignDest(p); return; }   // стоит у цели, потом новая цель
  const line = p.line; if (!line || line.length < 2 || !line[p.seg] || !line[p.seg + 1]) { p.dead = true; return; }
  const a = line[p.seg], b = line[p.seg + 1], len = distMeters(a[0], a[1], b[0], b[1]) || 1;
  p.t += (p.fwd ? 1 : -1) * p.spd * dt / len;
  if (p.route && p.route.length) {                              // идём по маршруту по сети
    const step = p.route[p.routeIdx];
    if (!step) { citizenArrive(p); return; }
    const done = p.fwd ? p.t >= step.t1 - 1e-6 : p.t <= step.t1 + 1e-6;
    if (!done) return;
    p.t = step.t1; p.routeIdx++;
    if (p.routeIdx >= p.route.length) { citizenArrive(p); return; }
    routeStepBegin(p);
    return;
  }
  if (p.t > 1) { if (p.seg < line.length - 2) { p.seg++; p.t = 0; } else citizenJunction(p, true); }
  else if (p.t < 0) { if (p.seg > 0) { p.seg--; p.t = 1; } else citizenJunction(p, false); }
  if (p.goal && p.line && p.line[p.seg + 1]) {                  // пришёл к цели?
    const pos = lerpPos(p.line, p.seg, p.t);
    if (distMeters(pos[0], pos[1], p.goal[0], p.goal[1]) < 7) citizenArrive(p);
  }
}
function pickCitizen(cp) {                          // ближайший житель к точке экрана (для клика)
  let best = null, bd = 16;
  for (const p of sim.peds) { const pos = pedestrianPosition(p); if (!pos) continue;
    const q = map.latLngToContainerPoint(pos), d = Math.hypot(q.x - cp.x, q.y - cp.y);
    if (d < bd) { bd = d; best = p; }
  }
  return best;
}
function selectCitizen(c) { sim.selected = c; sim.follow = true; document.getElementById('citizen').classList.remove('hidden'); updateCitizenPanel(); }
function deselectCitizen() { sim.selected = null; sim.follow = false; const p = document.getElementById('citizen'); if (p) p.classList.add('hidden'); }
function updateCitizenPanel() {
  const c = sim.selected; if (!c) return;
  document.getElementById('cz-name').textContent = c.name;
  const dest = c.transit?.state === 'waiting' ? `станция ${c.waitingAtStation?.name || ''}`.trim()
    : c.transit?.state === 'onTrain' ? c.transit.destination?.name || 'поездка поездом'
      : c.dest?.type === 'station' ? c.dest.name || 'станция'
        : c.dest ? (c.dest.type === 'shop' ? 'магазин' : 'дом') : 'нет';
  document.getElementById('cz-body').innerHTML =
    `<div class="cz-row"><span>${c.female ? 'Женщина' : 'Мужчина'}, ${c.age}</span><span>${c.job}</span></div>` +
    `<div class="cz-row"><span>Статус</span><b>${c.status || 'идёт'}</b></div>` +
    `<div class="cz-row"><span>Направляется</span><b>${dest}</b></div>` +
    `<div class="cz-row"><span>Дом</span><b>${c.home ? 'есть' : 'нет'}</b></div>` +
    `<div class="cz-row"><span>Работа</span><b>${c.employed ? 'магазин' : 'нет'}</b></div>` +
    `<div class="cz-row"><span>Занятость</span><b>${c.employed ? 'работает' : 'безработный'}</b></div>`;
}
function roundRect(ctx, x, y, w, h, r) { ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r); ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath(); }
function drawCouplingTo(ctx, dpr, prevWagon, wagon) {   // сцепка-буфер между соседними вагонами
  if (!prevWagon || !prevWagon.pos || !wagon || !wagon.pos) return;
  const a = map.latLngToContainerPoint([prevWagon.pos[0], prevWagon.pos[1]]), b = map.latLngToContainerPoint([wagon.pos[0], wagon.pos[1]]);
  ctx.strokeStyle = 'rgba(28,22,12,.75)'; ctx.lineWidth = Math.max(1, mToPx(0.28)) * dpr; ctx.lineCap = 'round';
  ctx.beginPath(); ctx.moveTo(a.x * dpr, a.y * dpr); ctx.lineTo(b.x * dpr, b.y * dpr); ctx.stroke();
}
function drawVehicleShape(ctx, c, length, width, dpr, vehicleAngle) {
  if (c.type !== 'truck') {
    ctx.fillStyle = c.color; roundRect(ctx, -length / 2 * dpr, -width / 2 * dpr, length * dpr, width * dpr, Math.min(width / 2, 3) * dpr); ctx.fill();
    ctx.fillStyle = 'rgba(20,24,30,.6)'; ctx.fillRect(length * .12 * dpr, -width / 2 * dpr, length * .22 * dpr, width * dpr);
    return;
  }
  const spec = VEHICLE_TYPES.truck, cab = Math.min(length * .32, mToPx(spec.cabLength || 2.4)), trailer = Math.min(length * .73, mToPx(spec.trailerLength || 6.2)), gap = Math.max(1.2, mToPx(.35)), hitchX = length / 2 - cab;
  const relativeTrailerAngle = Number.isFinite(c.trailerAngle) && Number.isFinite(vehicleAngle) ? angleDelta(c.trailerAngle, vehicleAngle) : 0;
  ctx.save();
  ctx.translate(hitchX * dpr, 0); ctx.rotate(-relativeTrailerAngle);
  ctx.fillStyle = c.color; roundRect(ctx, -trailer * dpr, -width / 2 * dpr, trailer * dpr, width * dpr, Math.min(width / 2, 2.5) * dpr); ctx.fill();
  ctx.fillStyle = 'rgba(20,24,30,.35)'; ctx.fillRect(-trailer * .08 * dpr, -width * .42 * dpr, trailer * .06 * dpr, width * .84 * dpr);
  ctx.fillStyle = 'rgba(20,24,30,.52)'; ctx.fillRect(-trailer * .05 * dpr, -width * .46 * dpr, gap * dpr, width * .92 * dpr);
  ctx.restore();
  ctx.fillStyle = '#59636d'; roundRect(ctx, hitchX * dpr, -width / 2 * dpr, cab * dpr, width * dpr, Math.min(width / 2, 2.5) * dpr); ctx.fill();
  ctx.fillStyle = 'rgba(20,24,30,.72)'; ctx.fillRect((hitchX + cab * .16) * dpr, -width * .34 * dpr, cab * .45 * dpr, width * .68 * dpr);
  ctx.fillStyle = '#dfe7ef'; ctx.fillRect((hitchX + cab * .78) * dpr, -width * .38 * dpr, cab * .09 * dpr, width * .76 * dpr);
  ctx.fillStyle = '#252a30'; ctx.beginPath(); ctx.arc(hitchX * dpr, 0, Math.max(1.2, gap * .65) * dpr, 0, 6.2832); ctx.fill();
}
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
  for (const train of sim.trains) {
    if (train.dead || !train.line || !train.line[train.seg + 1] && !train.turn) continue;
    updateTrainChain(train);
    const wagons = train.wagons || []; if (!wagons.length) continue;
    const carCount = wagons.length, carLength = mToPx(TRAIN_WAGON_LEN), width = Math.max(1.2, mToPx(train.width));
    const nearWagon = wagons.find(w => w.pos);
    if (!nearWagon) continue;
    const cp0 = map.latLngToContainerPoint([nearWagon.pos[0], nearWagon.pos[1]]);
    if (cp0.x < -80 || cp0.y < -80 || cp0.x > W + 80 || cp0.y > H + 80) { /* вне экрана — рисуем только если хвост близко */ }
    for (let i = 0; i < carCount; i++) {
      const w = wagons[i]; if (!w || !w.pos) continue;
      const cp = map.latLngToContainerPoint([w.pos[0], w.pos[1]]);
      if (cp.x < -60 || cp.y < -60 || cp.x > W + 60 || cp.y > H + 60) continue;
      if (i > 0) drawCouplingTo(ctx, dpr, wagons[i - 1], w);   // сцепка ПОД вагонами (рисуем до вагона)
      ctx.save(); ctx.translate(cp.x * dpr, cp.y * dpr); ctx.rotate(-w.angle);
      if (i === 0) {                                          // локомотив: центр в w.pos (8 м позади носа), нос — на +8
        const gl = carLength * .42;
        ctx.fillStyle = TRAIN_LOCO_COLORS[train._locoColor || 0]; roundRect(ctx, -carLength * .5 * dpr, -width / 2 * dpr, carLength * dpr, width * dpr, Math.min(width * .45, 3) * dpr); ctx.fill();
        ctx.fillStyle = 'rgba(20,24,30,.35)'; ctx.fillRect(-carLength * .5 * dpr, -width * .5 * dpr, carLength * .35 * dpr, width * dpr);
        ctx.fillStyle = '#3a2f22'; ctx.fillRect((carLength * .42) * dpr, -width * .16 * dpr, carLength * .1 * dpr, width * .32 * dpr);
        ctx.fillStyle = '#9fd4ff'; ctx.fillRect((carLength * .15) * dpr, -width * .34 * dpr, carLength * .16 * dpr, width * .3 * dpr);
        ctx.fillStyle = '#ffe9b0'; ctx.beginPath(); ctx.arc(carLength * .5 * dpr, 0, Math.max(1.6, width * .16) * dpr, 0, 6.2832); ctx.fill();
      } else {                                                // пассажирский вагон
        ctx.fillStyle = '#dba942'; roundRect(ctx, -carLength * .5 * dpr, -width * .5 * dpr, carLength * dpr, width * dpr, Math.min(width * .45, 3) * dpr); ctx.fill();
        ctx.fillStyle = '#8a6d2f'; ctx.fillRect(-carLength * .5 * dpr, -width * .5 * dpr, carLength * dpr, width * .12 * dpr);
      }
      // окна вагона
      const winW = carLength * .1, winGap = carLength * .14, winX0 = -carLength * .42;
      ctx.fillStyle = 'rgba(36,43,52,.85)';
      for (let k = 0; k < 4; k++) ctx.fillRect((winX0 + k * (winW + winGap)) * dpr, -width * .27 * dpr, winW * dpr, width * .2 * dpr);
      ctx.restore();
    }
    const passengerCount = (train.passengers?.length || 0) + (train.inboundPassengers || 0);
    if (passengerCount > 0) {
      const front = wagons[0].pos, cp = map.latLngToContainerPoint(front), badgeX = (cp.x + Math.max(10, mToPx(TRAIN_COUPLING))) * dpr, badgeY = (cp.y - 11) * dpr;
      ctx.fillStyle = 'rgba(19,24,30,.94)'; roundRect(ctx, badgeX, badgeY, 22 * dpr, 14 * dpr, 5 * dpr); ctx.fill();
      ctx.fillStyle = '#fff1bd'; ctx.font = `700 ${9 * dpr}px system-ui, sans-serif`; ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.fillText(String(passengerCount), badgeX + 11 * dpr, badgeY + 7 * dpr);
    }
  }
  for (const c of sim.cars) {
    const r = c.line; if (!r || !r[c.seg + 1] || c.dead) continue;
    const pose = smoothCarPose(c); if (!pose) continue;
    const cl = Math.max(1.2, mToPx(vehicleLength(c))), cw = Math.max(0.6, mToPx(vehicleWidth(c)));
    const cp = map.latLngToContainerPoint([pose.pos[0], pose.pos[1]]); if (cp.x < -30 || cp.y < -30 || cp.x > W + 30 || cp.y > H + 30) continue;
    ctx.save(); ctx.translate(cp.x * dpr, cp.y * dpr); ctx.rotate(-pose.angle);
    drawVehicleShape(ctx, c, cl, cw, dpr, pose.angle);
    ctx.restore();
  }
  for (const actor of sim.parkedCars || []) {
    if (!actor.pos) continue;
    const cp = map.latLngToContainerPoint(actor.pos); if (cp.x < -30 || cp.y < -30 || cp.x > W + 30 || cp.y > H + 30) continue;
    ctx.save(); ctx.translate(cp.x * dpr, cp.y * dpr); ctx.rotate(-actor.angle);
    drawVehicleShape(ctx, actor, Math.max(1.2, mToPx(vehicleLength(actor))), Math.max(.6, mToPx(vehicleWidth(actor))), dpr, actor.angle);
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
    const pos = pedestrianPosition(p); if (!pos) continue;
    const cp = map.latLngToContainerPoint(pos); if (cp.x < -10 || cp.y < -10 || cp.x > W + 10 || cp.y > H + 10) continue;
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
    if (sim.t - sim._trafficT > 1) { sim._trafficT = sim.t; replenishTraffic(); replenishTrains(); }
    computeCarSpeeds(dt);
    for (const c of sim.cars) stepCar(c, dt);
    for (const train of sim.trains) stepTrain(train, dt);
    for (const p of sim.peds) stepPed(p, dt);
    stepParkingCars(dt);
    if (sim.cars.some(c => c.dead)) sim.cars = sim.cars.filter(c => !c.dead);
    if (sim.trains.some(train => train.dead)) sim.trains = sim.trains.filter(train => !train.dead);
    if (sim.peds.some(p => p.dead)) {
    sim.peds.filter(p => p.dead).forEach(p => {          // освобождаем рабочее место
      if (p.work) sim.workload.set(p.work, Math.max(0, (sim.workload.get(p.work) || 0) - 1));
    });
    sim.peds = sim.peds.filter(p => !p.dead);
  }
    if (sim.selected) {
      if (sim.selected.dead || !sim.peds.includes(sim.selected)) deselectCitizen();
      else {
        const s = sim.selected, pos = pedestrianPosition(s);
        if (sim.follow && pos) {               // камера следует за жителем, включая очередь на платформе
          const cp = map.latLngToContainerPoint(pos), cen = map.getSize().divideBy(2);
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
  if (!state.roads.length && !state.alleys.length && !state.rails.length) { flash('Сначала проложи дороги, переулки или ЖД-путь', true); return; }
  resizeSim(); buildSim(); sim.on = true; sim.last = 0;
  document.querySelector('[data-action="sim"]').classList.add('active');
  sim.raf = requestAnimationFrame(simLoop);
  flash(`Движение: ${sim.cars.length} машин, ${sim.trains.length} поездов, ${sim.peds.length} пешеходов`);
}
function stopSim() { sim.on = false; deselectCitizen(); if (sim.raf) cancelAnimationFrame(sim.raf); if (simCtx) simCtx.clearRect(0, 0, simCanvas.width, simCanvas.height); const b = document.querySelector('[data-action="sim"]'); if (b) b.classList.remove('active'); }
function toggleSim() { sim.on ? stopSim() : startSim(); }
function simValueText(mode, count) { return mode === 'fixed' ? `${count} шт.` : 'Авто'; }
function syncSimPanel() {
  const s = simulationSettings(), carMode = document.getElementById('sim-car-mode'), carCount = document.getElementById('sim-car-count'), carValue = document.getElementById('sim-car-value'), trainMode = document.getElementById('sim-train-mode'), trainCount = document.getElementById('sim-train-count'), trainValue = document.getElementById('sim-train-value'), hint = document.getElementById('sim-panel-hint');
  if (!carMode || !carCount || !trainMode || !trainCount) return;
  carMode.value = s.carMode; carCount.value = String(s.carCount); carCount.disabled = s.carMode !== 'fixed'; carValue.textContent = simValueText(s.carMode, s.carCount);
  trainMode.value = s.trainMode; trainCount.value = String(s.trainCount); trainCount.disabled = s.trainMode !== 'fixed'; trainValue.textContent = simValueText(s.trainMode, s.trainCount);
  hint.textContent = s.carMode === 'fixed' || s.trainMode === 'fixed' ? 'Фиксированное число сохраняется в карте. Авто-режим распределяет транспорт по длине сети.' : 'Авто-режим распределяет машины и поезда по длине всех дорог и путей.';
}
function openSimPanel() { syncSimPanel(); document.getElementById('sim-panel').classList.remove('hidden'); }
function closeSimPanel() { document.getElementById('sim-panel').classList.add('hidden'); }
function applySimSettings() {
  state.simulation = normalizeSimulation({ carMode: document.getElementById('sim-car-mode').value, carCount: Number(document.getElementById('sim-car-count').value), trainMode: document.getElementById('sim-train-mode').value, trainCount: Number(document.getElementById('sim-train-count').value) });
  save(); if (sim.on) { buildSim(); sim.last = 0; } syncSimPanel(); closeSimPanel(); flash('Настройки движения сохранены');
}

/* ════════════════ WIRING ════════════════ */
function positionToolTip(button, tooltip) {
  if (!button || !tooltip) return;
  const r = button.getBoundingClientRect(), gap = 10, tw = tooltip.offsetWidth, th = tooltip.offsetHeight;
  let left = r.right + gap;
  if (left + tw > innerWidth - 8) left = r.left - tw - gap;
  left = Math.max(8, left);
  const top = Math.max(th / 2 + 8, Math.min(innerHeight - th / 2 - 8, r.top + r.height / 2));
  tooltip.style.left = `${left}px`; tooltip.style.top = `${top}px`;
}
function wireToolTips() {
  const tooltip = document.getElementById('tool-tooltip'); if (!tooltip) return;
  let current = null;
  const hide = button => { if (current !== button) return; current = null; tooltip.classList.remove('visible'); tooltip.setAttribute('aria-hidden', 'true'); };
  const show = button => {
    const text = button.dataset.tip || button.getAttribute('title'); if (!text) return;
    current = button; tooltip.textContent = text; tooltip.classList.add('visible'); tooltip.setAttribute('aria-hidden', 'false'); positionToolTip(button, tooltip);
  };
  const targets = [...document.querySelectorAll('#toolbar .tool'), document.getElementById('tb-collapse'), document.getElementById('sim-config')].filter(Boolean);
  targets.forEach(button => {
    const text = button.dataset.tip || button.getAttribute('title'); if (!text) return;
    button.dataset.tip = text; button.setAttribute('aria-label', text); button.removeAttribute('title');
    button.addEventListener('pointerenter', () => show(button)); button.addEventListener('pointerleave', () => hide(button));
    button.addEventListener('mouseenter', () => show(button)); button.addEventListener('mouseleave', () => hide(button));
    button.addEventListener('focus', () => show(button)); button.addEventListener('blur', () => hide(button));
  });
  window.addEventListener('resize', () => { if (current) positionToolTip(current, tooltip); });
}
function wire() {
  const toolIcon = { 'road-oneway': 'road', dirt: 'road', 'dirt-oneway': 'road', 'alley-oneway': 'alley', split: 'select', station: 'rail', parking: 'car', exit: 'target' };
  const toolBadge = { 'road-oneway': '→', dirt: 'Г', 'dirt-oneway': 'Г→', 'alley-oneway': '→', split: '✂' };
  const toolTip = { borders: 'Границы: нарисовать или изменить границу страны', house: 'Жилой дом', shop: 'Магазин', road: 'Дорога с двусторонним движением', 'road-oneway': 'Односторонняя дорога · две полосы', dirt: 'Грунтовая дорога', 'dirt-oneway': 'Односторонняя грунтовка · две полосы', alley: 'Переулок или проезд', 'alley-oneway': 'Односторонний проезд', rail: 'ЖД-путь · узкий рельсовый маршрут', station: 'Станция на рельсах · сам подведи к входу дорогу, переулок или тропу; без соединения пассажиры не пользуются станцией', path: 'Пешеходная тропинка', parking: 'Автостоянка · машины заезжают и занимают места во время симуляции', exit: 'Выход · въезд и выезд машин, людей или поездов', tree: 'Дерево', district: 'Район: сначала граница страны, затем 3+ точек внутри неё и «Готово»', light: 'Светофор на перекрёстке', crosswalk: 'Пешеходный переход · ставится только на дороге', select: 'Выбрать и изменить объект', split: 'Разделить дорогу новой точкой', erase: 'Удалить объект' };
  document.querySelectorAll('.tool[data-tool]').forEach(b => {
    const t = b.dataset.tool, icon = toolIcon[t] || (t === 'erase' ? 'trash' : t), badge = toolBadge[t], label = b.dataset.label || null;
    b.dataset.tip = toolTip[t] || b.getAttribute('title') || t; b.title = b.dataset.tip;
    b.classList.toggle('tool-labeled', Boolean(label));
    b.classList.toggle('tool-dirt', t.startsWith('dirt'));
    b.classList.toggle('tool-oneway', t.endsWith('-oneway'));
    b.innerHTML = `<span class="tool-icon">${ICONS[icon] || ''}</span>${label ? `<span class="tool-label">${label}</span>` : ''}${badge && !label ? `<span class="tool-badge">${badge}</span>` : ''}`;
    b.onclick = () => setTool(t);
  });
  const map_ = { undo: ICONS.undo, save: ICONS.download, load: ICONS.upload };
  document.querySelector('[data-action="undo"]').innerHTML = map_.undo || ''; document.querySelector('[data-action="undo"]').onclick = undo;
  document.querySelector('[data-action="save"]').innerHTML = map_.save || ''; document.querySelector('[data-action="save"]').onclick = exportFile;
  document.querySelector('[data-action="load"]').innerHTML = map_.load || ''; document.querySelector('[data-action="load"]').onclick = () => document.getElementById('import-file').click();
  document.querySelector('[data-action="sim"]').innerHTML = ICONS.car || ''; document.querySelector('[data-action="sim"]').onclick = toggleSim;
  const toolbarTips = { undo: 'Отменить последнее действие', save: 'Сохранить карту в файл', load: 'Загрузить карту из файла', sim: 'Запустить или остановить движение', locate: 'Показать свою страну' };
  document.querySelectorAll('#toolbar .tool').forEach(b => { if (!b.dataset.tip) b.dataset.tip = toolbarTips[b.dataset.action] || (b.id === 'locate' ? toolbarTips.locate : b.getAttribute('title') || b.dataset.action || 'Инструмент'); b.title = b.dataset.tip; });
  const simConfig = document.getElementById('sim-config'); if (simConfig) { simConfig.innerHTML = '<svg viewBox="0 0 24 24" fill="none"><path d="M12 3.5l1.15 1.8 2.1.35.55 2.05 1.8 1.15-.55 2.05.55 2.05-1.8 1.15-.55 2.05-2.1.35L12 20.5l-1.15-1.8-2.1-.35-.55-2.05-1.8-1.15.55-2.05-.55-2.05 1.8-1.15.55-2.05 2.1-.35L12 3.5Z" stroke="currentColor" stroke-width="1.5"/><circle cx="12" cy="12" r="2.4" stroke="currentColor" stroke-width="1.5"/></svg>'; simConfig.dataset.tip = 'Настройки движения: количество машин и поездов'; simConfig.title = simConfig.dataset.tip; simConfig.onclick = openSimPanel; }
  const simClose = document.getElementById('sim-panel-close'); if (simClose) simClose.onclick = closeSimPanel;
  const simApply = document.getElementById('sim-panel-apply'); if (simApply) simApply.onclick = applySimSettings;
  ['sim-car-mode', 'sim-car-count', 'sim-train-mode', 'sim-train-count'].forEach(id => { const el = document.getElementById(id); if (el) el.oninput = el.onchange = syncSimPanel; });
  wireToolTips(); syncSimPanel();
  document.getElementById('import-file').onchange = e => { if (e.target.files[0]) importFile(e.target.files[0]); e.target.value = ''; };
  document.getElementById('locate').innerHTML = ICONS.target || ''; document.getElementById('locate').onclick = locate;
  document.getElementById('draw-undo').onclick = undoVertex;
  document.getElementById('draw-done').onclick = () => finishDraw(false);
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
  document.querySelectorAll('[data-walk]').forEach(b => b.onclick = () => {
    if (walkBarKey) {
      const line = state.roads.concat(state.alleys).find(r => roadKey(r) === walkBarKey);
      if (line) setLineWalk(line, b.dataset.walk); else state.roadWalk[walkBarKey] = b.dataset.walk;
      save(); renderRoads(); renderAlleys();
    }
    document.querySelectorAll('[data-walk]').forEach(x => x.classList.toggle('active', x === b)); closeWalkBar();
  });
  const nameEl = document.getElementById('state-name'), nameBtn = document.getElementById('name-apply');
  const syncNameBtn = () => {
    if (!nameBtn) return;
    const committed = nameEl.dataset.committed || '';
    nameBtn.classList.toggle('hidden', nameEl.value.trim() === committed || !nameEl.value.trim());
  };
  nameEl.value = state.name;
  nameEl.dataset.committed = state.name || '';
  nameEl.oninput = () => { state.name = nameEl.value.trim(); save(); syncNameBtn(); };
  nameEl.onkeydown = e => { if (e.key === 'Enter') { e.preventDefault(); applyCountryName(); } };
  if (nameBtn) nameBtn.onclick = applyCountryName;
  syncNameBtn();
  document.getElementById('flag').onclick = () => document.getElementById('palette').classList.toggle('hidden');
  document.querySelectorAll('.layer').forEach(b => { b.onclick = () => { const id = b.dataset.layer; if (id === currentLayer) return; map.removeLayer(layers[currentLayer]); layers[id].addTo(map); currentLayer = id; document.querySelectorAll('.layer').forEach(x => x.classList.toggle('active', x === b)); }; });
  const panKeys = { KeyW: [0, -1], KeyS: [0, 1], KeyA: [-1, 0], KeyD: [1, 0] }, held = {};   // e.code — работает в любой раскладке
  function stopPan() { for (const k of Object.keys(held)) delete held[k]; panTimer = 0; }
  let panTimer = 0;
  function stepPan() {                                    // сдвиг карты в сторону зажатой клавиши (плавно, как в играх)
    let x = 0, y = 0;
    for (const k of Object.keys(held)) { const d = panKeys[k]; x += d[0]; y += d[1]; }
    if (!x && !y) return stopPan();
    const len = Math.hypot(x, y) || 1, px = mpp() * 240, py = px;
    map.panBy(L.point(Math.round(x / len * px), Math.round(y / len * py)), { animate: false });
  }
  document.addEventListener('keydown', e => {
    const k = e.key.toLowerCase();
    if (panKeys[e.code] && !(e.ctrlKey || e.metaKey || e.altKey) && !(e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.isContentEditable))) {
      if (!held[e.code]) { held[e.code] = true; if (panTimer) { clearInterval(panTimer); panTimer = 0; } panTimer = setInterval(stepPan, 50); }   // не звать stopPan — он чистит held
      return;
    }
    if ((e.ctrlKey || e.metaKey) && k === 's') { e.preventDefault(); exportFile(); }
    else if ((e.ctrlKey || e.metaKey) && k === 'z') { e.preventDefault(); undo(); }
    else if ((e.ctrlKey || e.metaKey) && k === 'c') { copySel(); }
    else if ((e.ctrlKey || e.metaKey) && k === 'v') { e.preventDefault(); paste(); }
    else if (e.key === 'Enter' && draw.active) finishDraw();
    else if (e.key === 'Delete' && selected) removeBuilding(selected);
    else if (e.key === 'Escape') { closeCtxMenu(); closeWalkBar(); if (genSel.active) endGenSelect(); else if (draw.active) { cancelDraw(); setToolIdle(); } else if (borderEdit.active) { exitBorderEdit(); setToolIdle(); } else if (selected) deselect(); else document.getElementById('palette').classList.add('hidden'); }
    else if (e.key === 'Backspace' && draw.active) { e.preventDefault(); undoVertex(); }
  });
  document.addEventListener('keyup', e => { if (panKeys[e.code] && held[e.code]) { delete held[e.code]; if (!Object.keys(held).length) stopPan(); } });
  window.addEventListener('blur', stopPan);
}

/* ════════════════ BOOT ════════════════ */
/* ════════════════ МУЛЬТИПЛЕЕР (общий мир, аккаунты GhostEcos) ════════════════ */
const MP_API = '/api/nation';
const mp = { mode: localStorage.getItem('ghostnation:mode') === 'mp' ? 'mp' : 'local', country: null, balance: 0, pop: 0, econ: null, worldLayer: null, saveTimer: null, incomeTimer: null, world: new Map(), layers: new Map(), ws: null, wsReady: false, wsRetry: 0, wsTimer: 0, wsSubTimer: 0, confirmed: null };
let mpWorldLoadTimer = 0, mpWorldLoadInFlight = false, mpWorldLoadAgain = false;
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
  const t = ssoToken() ? await mpToken() : null;   // без входа не дёргаем SSO
  if (t) h['Authorization'] = 'Bearer ' + t;
  return fetch(MP_API + path, Object.assign({}, opts, { headers: Object.assign(h, opts.headers || {}) }));
}
function mpInit() {
  if (!document.getElementById('mode-local')) return;   // UI мультиплеера ещё не добавлен → MP спит, играем локально
  mp.worldLayer = L.layerGroup().addTo(map);
  document.getElementById('mode-local').onclick = () => setMode('local');
  document.getElementById('mode-mp').onclick = () => setMode('mp');
  document.getElementById('mp-login-go').onclick = mpSubmitLogin;
  document.getElementById('mp-login-cancel').onclick = () => hideMpLogin();
  const loginOpen = document.getElementById('mp-login-open');
  if (loginOpen) loginOpen.onclick = showMpLogin;
  const cClose = document.getElementById('mpc-close');
  if (cClose) cClose.onclick = mpHideCountryCard;
  const regBtn = document.getElementById('mp-login-register');
  if (regBtn) regBtn.onclick = mpGoRegister;
  document.getElementById('mp-logout').onclick = mpLogout;
  updateModeUI();
  startMpIncomeRefresh();
  if (isMP()) enterMP();
}
function setMode(m) {
  if (m === mp.mode) return;
  if (mp.mode === 'local') localStorage.setItem(STORE_KEY, JSON.stringify(state));
  mp.mode = m; localStorage.setItem('ghostnation:mode', m); updateModeUI();
  if (m === 'local') { mpWsClose(); mp.world.clear(); mp.layers.clear(); mp.worldLayer.clearLayers(); mp.country = null; state = load(); document.getElementById('state-name').value = state.name; renderAll(); flash('Локальный режим'); }
  else enterMP();
}
function updateModeUI() {
  document.getElementById('mode-local').classList.toggle('active', !isMP());
  document.getElementById('mode-mp').classList.toggle('active', isMP());
  document.getElementById('mp-bar').classList.toggle('hidden', !isMP());
  if (isMP()) updateBalanceUI();
}
function updateBalanceUI() {
  const logged = !!ssoToken();
  const b = document.getElementById('mp-balance');
  if (b) b.textContent = logged ? Math.round(mp.balance) + ' gost' : 'Режим просмотра';
  const p = document.getElementById('mp-pop');
  if (p) { p.textContent = logged ? mp.pop + ' чел' : ''; p.classList.toggle('hidden', !logged); }
  const inc = document.getElementById('mp-income');
  if (inc) {
    const e = mp.econ;
    inc.textContent = logged ? (e ? (e.net >= 0 ? '+' : '') + Math.round(e.net) + ' gost/ч' : '≈' + Math.round(mp.pop * 2) + ' gost/ч') : '';
    if (e) inc.title = `Доход ${Math.round(e.income)} · содержание ${Math.round(e.upkeep)} · жителей ${e.residents} · рабочих мест ${e.jobs} · безработных ${e.unemployed}`;
    inc.classList.toggle('hidden', !logged);
  }
  const lo = document.getElementById('mp-logout'); if (lo) lo.classList.toggle('hidden', !logged);
  const li = document.getElementById('mp-login-open'); if (li) li.classList.toggle('hidden', logged);
}
function enterMP() {
  mpWsConnect(); mpLoadWorld();          // мир грузим всегда: и без входа, и при мёртвом JWT
  if (!ssoToken()) return;               // аноним смотрит мир сразу, вход — по кнопке «Войти»
  mpLoadMine();
}
// Доход капает на сервере: пока страна открыта, подтягиваем баланс раз в минуту
function startMpIncomeRefresh() {
  if (mp.incomeTimer) return;
  mp.incomeTimer = setInterval(async () => {
    if (!isMP() || !ssoToken() || document.visibilityState !== 'visible') return;
    try {
      const r = await mpApi('/mine');
      if (!r.ok) return;
      const d = await r.json();
      if (!d.country) return;
      mp.balance = d.country.balance;
      mp.pop = d.country.population != null ? d.country.population : mp.pop;
      mp.econ = d.country.economy || mp.econ;
      updateBalanceUI();
    } catch (e) {}
  }, 60000);
}
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
      mp.econ = c.economy || null;
      state = migrate(Object.assign(freshState(), c.state || {})); state.name = c.name || ''; state.color = c.color || state.color; state.border = c.border || null;
      ensureWalkways(false);                                     // восстановить тропинки от входов, если их нет
      mpResetSent(); mp.confirmed = JSON.stringify(state);
      document.getElementById('state-name').value = state.name; renderAll(); updateBalanceUI();
      if (state.border && state.border.length) try { map.fitBounds(L.latLngBounds(state.border).pad(0.25)); } catch (e) {}
      flash('Загружена твоя страна');
    } else { mp.country = null; mp.balance = 1500; mp.pop = 0; state = freshState(); const cached = load(); if (cached && cached.buildings?.length) { state = cached; flash('Страна не найдена — показан последний местный мир'); } else { mpResetSent(); mp.confirmed = JSON.stringify(state); renderAll(); updateBalanceUI(); flash('Нарисуй границу — застолби свою территорию', true); } }
  } catch (e) { flash('Сервер недоступен', true); }
}
// Частичное сохранение: на сервер уходят только изменившиеся коллекции состояния
const MP_STATE_KEYS = ['buildings', 'roads', 'alleys', 'rails', 'paths', 'districts',
  'lights', 'roadWalk', 'lineMeta', 'noZebra', 'crosswalks', 'stations', 'exits', 'parking', 'simulation'];
function mpResetSent() { mp.sent = null; }
function mpStatePatch() {
  const cur = {}, keys = [];
  for (const k of MP_STATE_KEYS) cur[k] = JSON.stringify(state[k] === undefined ? null : state[k]);
  if (!mp.sent) { mp.sent = cur; return { state, keys: null }; }   // первый раз — целиком
  for (const k of MP_STATE_KEYS) if (cur[k] !== mp.sent[k]) keys.push(k);
  if (!keys.length) return null;
  const patch = {};
  for (const k of keys) patch[k] = state[k];
  mp.sent = cur;
  return { state: patch, keys };
}
function mpSetSaveState(text, ok) {
  const el = document.getElementById('mp-saved');
  if (el) { el.textContent = text; el.title = text; el.dataset.state = ok ? 'ok' : 'err'; }
}
// Откат к последнему состоянию, принятому сервером: неоплаченный объект исчезает локально
function mpRollbackLocal() {
  if (!mp.confirmed) return false;
  try { state = migrate(Object.assign(freshState(), JSON.parse(mp.confirmed))); } catch (e) { return false; }
  mpResetSent();
  try { deselect(); clearHover(); } catch (e) {}
  const nameEl = document.getElementById('state-name');
  if (nameEl) nameEl.value = state.name || '';
  try { buildPalette(); renderAll(); updateStats(); } catch (e) {}
  return true;
}
function mpSyncSave() {
  if (!isMP() || !ssoToken() || !mp.country) return;
  clearTimeout(mp.saveTimer);
  mp.saveTimer = setTimeout(async () => {
    const patch = mpStatePatch();
    if (!patch) return;
    try {
      mpSetSaveState('Сохраняю…', true);
      const body = patch.keys ? { state: patch.state, keys: patch.keys } : { state: patch.state };
      const r = await mpApi('/mine', { method: 'PUT', body: JSON.stringify(body) });
      if (r.ok) {
        const d = await r.json();
        mp.confirmed = JSON.stringify(state);          // что сервер уже принял
        mp.econ = d.economy || mp.econ;
        mp.balance = d.balance; mp.pop = d.population != null ? d.population : mp.pop; updateBalanceUI();
        mpSetSaveState('Сохранено', true);
      } else if (r.status === 402) {
        const d = await r.json().catch(() => ({}));
        mpRollbackLocal();
        mpSetSaveState('Не хватает gost', false);
        flash((d.detail || 'Не хватает gost') + ' — изменение отменено', true);
      } else if (r.status === 400 || r.status === 409 || r.status === 413) {
        mpRollbackLocal();
        mpSetSaveState('Изменение отменено', false);
        flash('Сервер отклонил изменения (' + r.status + ') — откатил локально', true);
      } else {
        mpResetSent();
        mpSetSaveState('Не сохранено', false);
        flash('Сервер не принял изменения (' + r.status + ')', true);
      }
    } catch (e) {
      mpResetSent();
      mpSetSaveState('Нет связи', false);
    }
  }, 900);
}
// Переименование страны: локально сразу, в мире — через claim (та же граница, плата 0)
async function applyCountryName() {
  const input = document.getElementById('state-name'), btn = document.getElementById('name-apply');
  const name = ((input ? input.value : state.name) || '').trim().slice(0, 80);
  if (!name) { flash('Название не может быть пустым', true); if (input) input.focus(); return; }
  state.name = name;
  if (input) { input.value = name; input.dataset.committed = name; }
  if (btn) btn.classList.add('hidden');
  save(); renderAll();
  if (!isMP() || !ssoToken() || !state.border || state.border.length < 3) { flash('Название сохранено'); return; }
  try {
    const r = await mpApi('/claim', { method: 'POST', body: JSON.stringify({ name, color: state.color, border: state.border }) });
    const d = await r.json().catch(() => ({}));
    if (r.ok) {
      mp.country = Object.assign(mp.country || {}, { name });
      if (d.balance != null) mp.balance = d.balance;
      updateBalanceUI(); mpLoadWorld();
      flash('Название сохранено' + (d.cost ? ' · −' + Math.round(d.cost) + ' gost' : ''));
    } else flash(d.detail || 'Не удалось сохранить название', true);
  } catch (e) { flash('Сервер недоступен', true); }
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
function scheduleMpWorldLoad(delay = 120) {
  if (!isMP() || !map || !mp.worldLayer) return;
  if (mp.wsReady) {                          // WS жив: только переподписка на новый bbox
    if (mp.wsSubTimer) { if (delay > 0) return; clearTimeout(mp.wsSubTimer); mp.wsSubTimer = 0; }
    mp.wsSubTimer = setTimeout(() => { mp.wsSubTimer = 0; mpWsSubscribe(); }, Math.max(0, delay));
    return;
  }
  if (mpWorldLoadInFlight) { mpWorldLoadAgain = true; return; }
  if (mpWorldLoadTimer) {
    if (delay > 0) return;
    clearTimeout(mpWorldLoadTimer); mpWorldLoadTimer = 0;
  }
  if (delay <= 0) { mpLoadWorld(); return; }
  mpWorldLoadTimer = setTimeout(() => { mpWorldLoadTimer = 0; mpLoadWorld(); }, delay);
}

/* ── Мир в реальном времени: снимок bbox по WS + push изменений ── */
function mpBoundsMsg() {
  const b = map.getBounds();
  return { type: 'sub', minlat: b.getSouth(), minlng: b.getWest(), maxlat: b.getNorth(), maxlng: b.getEast() };
}
function mpWsClose() {
  if (mp.wsSubTimer) { clearTimeout(mp.wsSubTimer); mp.wsSubTimer = 0; }
  if (mp.wsTimer) { clearTimeout(mp.wsTimer); mp.wsTimer = 0; }
  if (mp.ws) { try { mp.ws.onclose = null; mp.ws.close(); } catch (e) {} }
  mp.ws = null; mp.wsReady = false;
}
function mpWsRetry() {
  if (!isMP() || mp.wsTimer) return;
  mp.wsRetry = Math.min((mp.wsRetry || 0) + 1, 6);
  mp.wsTimer = setTimeout(() => { mp.wsTimer = 0; mpWsConnect(); }, Math.min(15000, 700 * Math.pow(2, mp.wsRetry - 1)));
}
async function mpWsConnect() {
  if (!isMP() || !mp.worldLayer || mp.ws) return;
  const t = ssoToken() ? await mpToken() : null;   // может быть null: мир смотрим и без входа
  const scheme = location.protocol === 'https:' ? 'wss://' : 'ws://';
  const url = scheme + location.host + '/api/nation/ws' + (t ? '?token=' + encodeURIComponent(t) : '');
  let ws;
  try { ws = new WebSocket(url); }
  catch (e) { mpWsRetry(); return; }
  mp.ws = ws;
  ws.onopen = () => { mp.wsReady = true; mp.wsRetry = 0; mpWsSubscribe(); };
  ws.onmessage = ev => { let msg; try { msg = JSON.parse(ev.data); } catch (e) { return; } mpWsHandle(msg); };
  ws.onclose = () => { mp.ws = null; mp.wsReady = false; mpWsRetry(); };
  ws.onerror = () => {};
}
function mpWsSubscribe() {
  if (mp.ws && mp.ws.readyState === 1 && map) mp.ws.send(JSON.stringify(mpBoundsMsg()));
}
function mpWsHandle(msg) {
  if (!msg || typeof msg !== 'object') return;
  if (msg.type === 'snapshot') {
    mp.world.clear();
    for (const c of msg.countries || []) if (c && c.owner) mp.world.set(c.owner, c);
    mpWorldRedraw();
  } else if (msg.type === 'country' && msg.country && msg.country.owner) {
    mp.world.set(msg.country.owner, msg.country);
    mpWorldUpsert(msg.country);
  } else if (msg.type === 'remove' && msg.owner) {
    mpWorldRemove(msg.owner);
  }
}
// Линии чужой страны: дороги, переулки, тропинки, жд — в тех же цветах, что и свои
function mpForeignMeta(c, line) {
  const map = c.lineMeta || {};
  return normalizeLineMeta(map[roadKey(line)]);
}
function mpForeignWalk(c, line, dflt) {
  const w = (c.roadWalk || {})[roadKey(line)];
  return w === 'both' || w === 'left' || w === 'right' || w === 'none' ? w : dflt;
}
function mpDrawForeignLines(g, c) {
  const lines = c.lines || {}, wpx = m => Math.max(1, mToPx(m)), sw = Math.max(2, mToPx(LINE_M.path + 0.6));
  const sidewalks = (line, widthM, walk) => {
    const off = widthM / 2 + 1;
    const sides = walk === 'both' ? [off, -off] : walk === 'left' ? [off] : walk === 'right' ? [-off] : [];
    sides.forEach(o => L.polyline(offsetLine(line, o), { pane: 'pane-path', color: '#b7b9bc', weight: sw, opacity: .92, interactive: false, lineCap: 'round' }).addTo(g));
  };
  for (const line of lines.roads || []) {
    const meta = mpForeignMeta(c, line), dirt = meta.surface === 'dirt', widthM = dirt ? LINE_M.dirt : LINE_M.road, w = wpx(widthM);
    sidewalks(line, widthM, mpForeignWalk(c, line, 'both'));
    L.polyline(line, { pane: dirt ? 'pane-dirt' : 'pane-lines', color: dirt ? '#886548' : '#3b3f45', weight: w, opacity: .95, dashArray: dirt ? '10 5' : null, lineCap: 'round', lineJoin: 'round', interactive: false }).addTo(g);
    if (!dirt) L.polyline(line, { pane: 'pane-lines', color: meta.oneWay ? '#e5e7eb' : '#f2c200', weight: Math.max(1, w * .11), opacity: .9, interactive: false }).addTo(g);
  }
  for (const line of lines.alleys || []) {
    const meta = mpForeignMeta(c, line), dirt = meta.surface === 'dirt', widthM = dirt ? LINE_M.dirt : LINE_M.alley;
    sidewalks(line, widthM, mpForeignWalk(c, line, 'none'));
    L.polyline(line, { pane: 'pane-alley', color: dirt ? '#886548' : '#54585f', weight: wpx(widthM), opacity: .95, dashArray: dirt ? '10 5' : null, lineCap: 'round', lineJoin: 'round', interactive: false }).addTo(g);
  }
  for (const line of lines.paths || []) {
    L.polyline(line, { pane: 'pane-path', color: '#b7b9bc', weight: wpx(LINE_M.path), opacity: .95, lineCap: 'round', interactive: false }).addTo(g);
  }
  for (const line of lines.rails || []) {
    const w = wpx(LINE_M.rail);
    L.polyline(line, { pane: 'pane-lines', color: '#6b6f76', weight: w, opacity: .9, interactive: false }).addTo(g);
    L.polyline(line, { pane: 'pane-lines', color: '#d0d0d0', weight: Math.max(1, w * .35), dashArray: `${Math.max(3, w)} ${Math.max(4, w * 1.2)}`, interactive: false }).addTo(g);
  }
}
// Карточка чужой страны — только просмотр
function mpForeignStats(c) {
  const list = Array.isArray(c.buildings) ? c.buildings : [];
  const houses = list.filter(b => b && b.type === 'house').length;
  const shops = list.filter(b => b && b.type === 'shop').length;
  const trees = list.filter(b => b && b.type === 'tree').length;
  const pop = Math.min(houses * 4, shops * 12 + houses);
  let area = 0;
  try { if (Array.isArray(c.border) && c.border.length >= 3) area = geodesicArea(c.border); } catch (e) {}
  return { houses, shops, trees, pop, area };
}
function mpShowCountryCard(c) {
  const panel = document.getElementById('mp-country');
  if (!panel || !c) return;
  const s = mpForeignStats(c);
  document.getElementById('mpc-name').textContent = c.name || c.owner;
  document.getElementById('mpc-body').innerHTML =
    `<div class="mpc-row"><span>Владелец</span><b>${escLabel(c.owner || '—')}</b></div>` +
    `<div class="mpc-row"><span>Площадь</span><b>${s.area ? s.area.toFixed(2) + ' км²' : '—'}</b></div>` +
    `<div class="mpc-row"><span>Домов / магазинов</span><b>${s.houses} / ${s.shops}</b></div>` +
    `<div class="mpc-row"><span>Деревьев</span><b>${s.trees}</b></div>` +
    `<div class="mpc-row"><span>Жителей (оценка)</span><b>≈${s.pop}</b></div>` +
    `<div class="mpc-hint">Данные по видимой части страны, без построек за пределами экрана.</div>`;
  panel.classList.remove('hidden');
}
function mpHideCountryCard() { const p = document.getElementById('mp-country'); if (p) p.classList.add('hidden'); }
// Чужая страна: контур, подпись, дороги и её постройки — только просмотр
function mpCountryLayer(c) {
  const g = L.layerGroup();
  const border = L.polygon(c.border, { pane: 'pane-territory', color: c.color || '#888', weight: 2, opacity: .6, fillColor: c.color || '#888', fillOpacity: .07, interactive: true, dashArray: '5 4' });
  border.on('click', e => { L.DomEvent.stop(e); mpShowCountryCard(c); });
  border.addTo(g);
  if (map.getZoom() <= LABEL_MAX_ZOOM) L.marker(borderCentroid(c.border), { pane: 'markerPane', interactive: false, icon: L.divIcon({ className: 'country-label-wrap', html: `<div class="country-label" style="--c:${c.color || '#888'}">${escLabel(c.name || c.owner)}</div>`, iconSize: [0, 0], iconAnchor: [0, 0] }) }).addTo(g);
  mpDrawForeignLines(g, c);
  for (const b of (Array.isArray(c.buildings) ? c.buildings : [])) {
    if (!isFinite(b.lat) || !isFinite(b.lng)) continue;
    if (b.type === 'tree') drawTree(b, g); else drawHouse(b, g);
  }
  return g;
}
function mpWorldUpsert(c) {
  if (!mp.worldLayer || !c || !c.owner) return;
  if (mp.country && c.owner === mp.country.owner) return;
  if (!Array.isArray(c.border) || c.border.length < 3) return;
  const old = mp.layers.get(c.owner);
  if (old) mp.worldLayer.removeLayer(old);
  mp.layers.set(c.owner, mpCountryLayer(c).addTo(mp.worldLayer));
}
function mpWorldRemove(owner) {
  const g = mp.layers.get(owner);
  if (g && mp.worldLayer) mp.worldLayer.removeLayer(g);
  mp.layers.delete(owner);
  mp.world.delete(owner);
}
function mpWorldRedraw() {
  if (!mp.worldLayer) return;
  mp.worldLayer.clearLayers();
  mp.layers.clear();
  for (const c of mp.world.values()) mpWorldUpsert(c);
}
async function mpLoadWorld() {
  if (!isMP() || !map || !mp.worldLayer) return;
  if (mp.wsReady) { mpWsSubscribe(); return; }
  if (mpWorldLoadInFlight) { mpWorldLoadAgain = true; return; }
  mpWorldLoadInFlight = true;
  const b = map.getBounds();
  try {
    const r = await mpApi(`/world?minlat=${b.getSouth()}&minlng=${b.getWest()}&maxlat=${b.getNorth()}&maxlng=${b.getEast()}`), d = await r.json();
    if (isMP() && mp.worldLayer) mpRenderWorld(d.countries || []);
  } catch (e) {}
  finally {
    mpWorldLoadInFlight = false;
    if (mpWorldLoadAgain) { mpWorldLoadAgain = false; scheduleMpWorldLoad(80); }
  }
}
// REST-фолбэк: только границы без построек (полный набор даёт снимок по WS)
function mpRenderWorld(countries) {
  mp.world.clear();
  for (const c of countries) if (c && c.owner) mp.world.set(c.owner, c);
  mpWorldRedraw();
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
  transportLayer = L.layerGroup().addTo(map);
  countryLabelLayer = L.layerGroup().addTo(map);
  editLayer = L.layerGroup().addTo(map);
  buildPalette(); wire(); renderAll(); mpInit();
  simCanvas = document.getElementById('sim'); simCtx = simCanvas.getContext('2d'); resizeSim();
  window.addEventListener('resize', resizeSim);
})();
