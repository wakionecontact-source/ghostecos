/* GhostEcos global player.
 *
 * This file owns the shared visual shell and its browser-side behaviour.
 * Applications publish a small provider-neutral track object through
 * GhostPlayer.publish().  GhoSou is the first provider; GhoSoc and GhoChat
 * can publish the same shape later without creating another player UI.
 */
(function () {
  'use strict';

  var STORAGE_KEY = 'ghost_global_player_v1';
  var CHANNEL_NAME = 'ghost-global-player-v1';
  var STATE_TTL = 30 * 24 * 60 * 60 * 1000;
  var CLIENT_ID = 'gp_' + Math.random().toString(36).slice(2) + Date.now().toString(36);
  var existingHost = !!document.getElementById('player-bar');
  var host = null;
  var audio = null;
  var state = null;
  var options = {};
  var booted = false;
  var lastPersistAt = 0;
  var channel = null;
  var probeAudio = null;
  var probeTimer = null;
  var probeKey = '';
  var verifiedKey = '';
  var failedKey = '';

  try {
    if ('BroadcastChannel' in window) {
      channel = new BroadcastChannel(CHANNEL_NAME);
      channel.onmessage = function (event) {
        if (event && event.data && event.data.type === 'state') receiveState(event.data.state);
      };
    }
  } catch (e) {
    channel = null;
  }

  function numberOr(value, fallback) {
    var n = Number(value);
    return isFinite(n) && n >= 0 ? n : fallback;
  }

  function safeRelativeUrl(value) {
    var url = String(value || '');
    return url.charAt(0) === '/' && url.indexOf('//') !== 0 ? url : '';
  }

  function streamUrlFor(raw, source, slug) {
    var direct = safeRelativeUrl(raw.streamUrl || raw.stream_url || raw.audioUrl || raw.audio_url);
    if (direct && /^\/sound\/(stream|media)\//.test(direct)) return direct;
    if (source === 'ghosou' && slug) return '/sound/stream/' + encodeURIComponent(slug);
    return '';
  }

  function coverUrlFor(raw, id) {
    var direct = safeRelativeUrl(raw.coverUrl || raw.cover_url || raw.cover);
    if (direct && /^\/sound\/covers\/[a-f0-9]{24}\.jpg$/i.test(direct)) return direct;
    return /^[a-f0-9]{24}$/i.test(id) && (raw.hasCover || raw.cover === true)
      ? '/sound/covers/' + id + '.jpg'
      : '';
  }

  function detailUrlFor(raw, source, id) {
    var direct = safeRelativeUrl(raw.detailUrl || raw.detail_url || raw.pageUrl || raw.page_url);
    if (direct) return direct;
    return source === 'ghosou' && id ? '/sound/?track=' + encodeURIComponent(id) : '';
  }

  function normalize(raw) {
    if (!raw || typeof raw !== 'object') return null;
    var source = String(raw.source || raw.provider || 'ghosou').toLowerCase().slice(0, 32);
    var id = String(raw.id || raw.ID || raw.trackId || raw.track_id || '').slice(0, 128);
    var slug = String(raw.slug || raw.Slug || '').slice(0, 240);
    var streamUrl = streamUrlFor(raw, source, slug);
    if (!id && !slug && !streamUrl) return null;
    var playing = raw.playing;
    if (playing == null) playing = raw.isPlaying;
    var ready = raw.ready;
    if (ready == null) ready = raw.available;
    if (ready == null) ready = raw.canPlay;
    if (ready == null) ready = raw.ready_to_play;
    if (ready != null) ready = !!ready;
    var currentTime = numberOr(raw.currentTime == null ? raw.current_time : raw.currentTime, 0);
    var duration = numberOr(raw.duration, 0);
    return {
      version: 1,
      source: source,
      id: id,
      slug: slug,
      title: String(raw.title || raw.Title || 'Без названия').slice(0, 240),
      artist: String(raw.artist || raw.Artist || 'GhoSou').slice(0, 240),
      album: String(raw.album || raw.Album || '').slice(0, 240),
      coverUrl: coverUrlFor(raw, id),
      streamUrl: streamUrl,
      detailUrl: detailUrlFor(raw, source, id),
      duration: duration,
      currentTime: currentTime,
      playing: !!playing,
      ready: ready,
      owner: String(raw.owner || '').slice(0, 96),
      updatedAt: numberOr(raw.updatedAt || raw.updated_at, Date.now())
    };
  }

  function trackKey(next) {
    return next ? String(next.id || '') + '|' + String(next.streamUrl || '') : '';
  }

  function cancelProbe() {
    if (probeTimer) {
      clearTimeout(probeTimer);
      probeTimer = null;
    }
    if (probeAudio) {
      try {
        probeAudio.pause();
        probeAudio.removeAttribute('src');
        probeAudio.load();
      } catch (e) {}
      probeAudio = null;
    }
    probeKey = '';
  }

  function verifyTrack(next) {
    var key = trackKey(next);
    if (!next || !next.streamUrl || next.ready === false) {
      cancelProbe();
      verifiedKey = '';
      failedKey = '';
      return;
    }
    if (verifiedKey === key || probeKey === key || failedKey === key) return;
    cancelProbe();
    probeKey = key;
    var candidate = new Audio();
    probeAudio = candidate;
    candidate.preload = 'metadata';
    candidate.muted = true;
    candidate.volume = 0;
    var settled = false;
    function finish(ok) {
      if (settled) return;
      settled = true;
      if (probeKey !== key) return;
      if (probeTimer) {
        clearTimeout(probeTimer);
        probeTimer = null;
      }
      try {
        candidate.pause();
        candidate.removeAttribute('src');
        candidate.load();
      } catch (e) {}
      probeAudio = null;
      probeKey = '';
      if (ok) {
        verifiedKey = key;
        failedKey = '';
        render();
        return;
      }
      verifiedKey = '';
      failedKey = key;
      render();
      probeTimer = setTimeout(function () {
        if (state && trackKey(state) === key) {
          failedKey = '';
          verifyTrack(state);
        }
      }, 5000);
    }
    candidate.addEventListener('loadedmetadata', function () {
      if (candidate.duration === Infinity || (isFinite(candidate.duration) && candidate.duration > 0)) {
        if (candidate.readyState >= 2) finish(true);
      }
    });
    candidate.addEventListener('canplay', function () { finish(true); });
    candidate.addEventListener('error', function () { finish(false); });
    candidate.src = next.streamUrl;
    try { candidate.load(); } catch (e) { finish(false); }
    probeTimer = setTimeout(function () {
      var hasDuration = candidate.duration === Infinity || (isFinite(candidate.duration) && candidate.duration > 0);
      finish(candidate.readyState >= 2 && !candidate.error && hasDuration);
    }, 6500);
  }

  function readStoredState() {
    try {
      var raw = JSON.parse(localStorage.getItem(STORAGE_KEY) || 'null');
      if (!raw || (raw.updatedAt && Date.now() - raw.updatedAt > STATE_TTL)) return null;
      return normalize(raw);
    } catch (e) {
      return null;
    }
  }

  function persist(next, broadcast) {
    state = normalize(next);
    if (!state) return;
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(state)); } catch (e) {}
    if (broadcast && channel) {
      try { channel.postMessage({ type: 'state', state: state }); } catch (e) {}
    }
    emitStateChange(state, false);
  }

  function emitStateChange(next, remote) {
    try {
      window.dispatchEvent(new CustomEvent('ghostplayerchange', {
        detail: { state: normalize(next), remote: !!remote }
      }));
    } catch (e) {}
  }

  function publishPlayback(patch, force) {
    if (!state) return;
    var now = Date.now();
    if (!force && now - lastPersistAt < 280) return;
    lastPersistAt = now;
    var next = {};
    Object.keys(state).forEach(function (key) { next[key] = state[key]; });
    Object.keys(patch || {}).forEach(function (key) { next[key] = patch[key]; });
    next.owner = CLIENT_ID;
    next.updatedAt = now;
    persist(next, true);
  }

  function publish(track, patch) {
    var raw = {};
    Object.keys(state || {}).forEach(function (key) { raw[key] = state[key]; });
    Object.keys(track || {}).forEach(function (key) { raw[key] = track[key]; });
    Object.keys(patch || {}).forEach(function (key) { raw[key] = patch[key]; });
    var next = normalize(raw);
    if (!next) return null;
    next.owner = CLIENT_ID;
    next.updatedAt = Date.now();
    lastPersistAt = next.updatedAt;
    persist(next, true);
    if (booted) applyState(next, false);
    return next;
  }

  function receiveState(raw) {
    var next = normalize(raw);
    if (!next) return;
    if (state && next.updatedAt < state.updatedAt) return;
    if (state && next.updatedAt === state.updatedAt && next.owner === state.owner) return;
    applyState(next, true);
    emitStateChange(next, true);
  }

  function iconPlay() {
    return '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m8 5 11 7-11 7Z"/></svg>';
  }

  function iconPause() {
    return '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="6" y="5" width="4" height="14"/><rect x="14" y="5" width="4" height="14"/></svg>';
  }

  function iconSkip(direction) {
    return direction === 'prev'
      ? '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M19 20 9 12l10-8v16zM5 19V5h3v14H5z"/></svg>'
      : '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 4l10 8-10 8V4zM16 5h3v14h-3V5z"/></svg>';
  }

  function iconVolume() {
    return '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 10v4h4l5 4V6l-5 4H4z"/><path d="M16 9.5a4 4 0 0 1 0 5M18.5 7a7.5 7.5 0 0 1 0 10"/></svg>';
  }

  function iconOpen() {
    return '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M14 5h5v5M19 5l-8 8"/><path d="M19 13v5a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h5"/></svg>';
  }

  function mount(mountOptions) {
    options = mountOptions || options || {};
    if (existingHost || booted || !document.body) return;
    booted = true;
    host = document.createElement('aside');
    host.id = 'ghost-global-player';
    host.className = 'gp-page-' + String(options.page || 'app').replace(/[^a-z0-9_-]/gi, '');
    host.setAttribute('aria-label', 'Общий проигрыватель GhostEcos');
    host.innerHTML = '<div class="gp-shell" data-liquid-glass="true">' +
      '<button type="button" class="gp-track-link" data-gp-action="open" title="Открыть страницу звука">' +
        '<span class="gp-art"><span class="gp-art-placeholder" aria-hidden="true">∿</span></span>' +
        '<span class="gp-copy"><span class="gp-now">PLAYER READY</span><strong class="gp-title">Выберите звук</strong><span class="gp-artist">Источник: GhoSou</span><span class="gp-remote-note">Нажмите ▶, чтобы продолжить</span></span>' +
      '</button>' +
      '<div class="gp-core"><div class="gp-controls">' +
        '<button type="button" class="gp-control" data-gp-action="prev" title="Предыдущий" aria-label="Предыдущий" disabled>' + iconSkip('prev') + '</button>' +
        '<button type="button" class="gp-control gp-play" data-gp-action="toggle" title="Воспроизвести" aria-label="Воспроизвести">' + iconPlay() + '</button>' +
        '<button type="button" class="gp-control" data-gp-action="next" title="Следующий" aria-label="Следующий" disabled>' + iconSkip('next') + '</button>' +
      '</div><div class="gp-timeline"><span class="gp-time" data-gp-time="current">0:00</span><div class="gp-progress" data-gp-action="seek" role="slider" tabindex="0" aria-label="Позиция воспроизведения"><div class="gp-progress-fill"></div></div><span class="gp-time" data-gp-time="duration">0:00</span></div></div>' +
      '<div class="gp-actions"><label class="gp-volume" title="Громкость"><button type="button" class="gp-action" data-gp-action="mute" aria-label="Громкость">' + iconVolume() + '</button><input type="range" min="0" max="1" step="0.01" value="1" data-gp-action="volume" aria-label="Громкость"></label><button type="button" class="gp-action gp-action-open" data-gp-action="open">' + iconOpen() + '<span>Открыть</span></button></div>' +
    '</div>';
    document.body.appendChild(host);
    bindEvents();
    state = readStoredState();
    if (state) applyState(state, false);
  }

  function bindEvents() {
    if (!host) return;
    host.querySelectorAll('[data-gp-action]').forEach(function (element) {
      var action = element.getAttribute('data-gp-action');
      if (action === 'toggle') element.addEventListener('click', togglePlayback);
      else if (action === 'open') element.addEventListener('click', openTrack);
      else if (action === 'mute') element.addEventListener('click', toggleMute);
      else if (action === 'volume') element.addEventListener('input', function () { setVolume(element.value); });
      else if (action === 'seek') {
        element.addEventListener('click', seek);
        element.addEventListener('keydown', function (event) {
          if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
            event.preventDefault();
            seekByKeyboard(event.key === 'ArrowRight' ? 5 : -5);
          }
        });
      }
    });
    var volume = host.querySelector('[data-gp-action="volume"]');
    try {
      var stored = Number(localStorage.getItem('ghost_global_player_volume'));
      if (isFinite(stored)) volume.value = Math.max(0, Math.min(1, stored));
    } catch (e) {}
  }

  function ensureAudio(next) {
    if (!next || !next.streamUrl) return null;
    if (audio && audio.__ghostSrc === next.streamUrl) return audio;
    if (audio) {
      try { audio.pause(); audio.removeAttribute('src'); audio.load(); } catch (e) {}
    }
    audio = new Audio();
    audio.__ghostSrc = next.streamUrl;
    audio.preload = 'metadata';
    audio.volume = getVolume();
    audio.addEventListener('loadedmetadata', function () {
      if (!state || audio.__ghostSrc !== state.streamUrl) return;
      if (state.currentTime > 0 && state.currentTime < audio.duration) {
        try { audio.currentTime = state.currentTime; } catch (e) {}
      }
      if (audio.duration && isFinite(audio.duration)) state.duration = audio.duration;
      render();
    });
    audio.addEventListener('timeupdate', function () {
      if (!state || audio.__ghostSrc !== state.streamUrl) return;
      state.currentTime = audio.currentTime || 0;
      if (audio.duration && isFinite(audio.duration)) state.duration = audio.duration;
      publishPlayback({ currentTime: state.currentTime, duration: state.duration, playing: !audio.paused && !audio.ended }, false);
      render();
    });
    audio.addEventListener('progress', render);
    audio.addEventListener('play', function () {
      publishPlayback({ playing: true }, true);
      render();
    });
    audio.addEventListener('pause', function () {
      publishPlayback({ playing: false, currentTime: audio.currentTime || 0 }, true);
      render();
    });
    audio.addEventListener('ended', function () {
      publishPlayback({ playing: false, currentTime: 0 }, true);
      render();
    });
    audio.addEventListener('error', function () { render(); });
    audio.src = next.streamUrl;
    return audio;
  }

  function getVolume() {
    var input = host && host.querySelector('[data-gp-action="volume"]');
    var value = Number(input && input.value);
    return isFinite(value) ? Math.max(0, Math.min(1, value)) : 1;
  }

  function setVolume(value) {
    var normalized = Number(value);
    if (!isFinite(normalized)) normalized = 1;
    normalized = Math.max(0, Math.min(1, normalized));
    if (audio) audio.volume = normalized;
    try { localStorage.setItem('ghost_global_player_volume', String(normalized)); } catch (e) {}
    render();
  }

  function toggleMute() {
    var volume = host && host.querySelector('[data-gp-action="volume"]');
    if (!volume) return;
    var current = Number(volume.value);
    if (current > 0) {
      volume.dataset.beforeMute = String(current);
      volume.value = '0';
    } else {
      volume.value = volume.dataset.beforeMute || '1';
    }
    setVolume(volume.value);
  }

  function togglePlayback() {
    if (!state) return;
    // A remote page may currently own the audio.  Reflecting its playing
    // state must never create a second audio stream; the first click pauses
    // the owner through the shared state channel.
    if (state.playing && (!audio || audio.paused || audio.ended)) {
      publishPlayback({ playing: false }, true);
      render();
      return;
    }
    if (audio && !audio.paused && !audio.ended) {
      audio.pause();
      return;
    }
    var target = ensureAudio(state);
    if (!target) return;
    target.play().then(function () {
      publishPlayback({ playing: true }, true);
      render();
    }).catch(function () { render(); });
  }

  function disposeAudio() {
    if (!audio) return;
    try { audio.pause(); audio.removeAttribute('src'); audio.load(); } catch (e) {}
    audio = null;
  }

  function syncRemoteState(next) {
    if (!next || next.owner === CLIENT_ID) return;
    if (next.playing) {
      // Keep the button synchronized, but wait for an explicit click in this
      // tab before creating/starting a local Audio element.
      if (audio && !audio.paused && !audio.ended) audio.pause();
    } else if (audio && !audio.paused) {
      audio.pause();
    }
    render();
  }

  function openTrack() {
    if (!state || !state.detailUrl) return;
    window.location.href = state.detailUrl;
  }

  function seek(event) {
    if (!audio || !audio.duration || !isFinite(audio.duration)) return;
    var rect = event.currentTarget.getBoundingClientRect();
    var percent = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
    audio.currentTime = percent * audio.duration;
    publishPlayback({ currentTime: audio.currentTime }, true);
    render();
  }

  function seekByKeyboard(delta) {
    if (!audio || !isFinite(audio.duration)) return;
    audio.currentTime = Math.max(0, Math.min(audio.duration, audio.currentTime + delta));
    publishPlayback({ currentTime: audio.currentTime }, true);
    render();
  }

  function fmtTime(value) {
    value = Number(value);
    if (!isFinite(value) || value < 0) return '0:00';
    var minutes = Math.floor(value / 60);
    var seconds = Math.floor(value % 60);
    return minutes + ':' + (seconds < 10 ? '0' : '') + seconds;
  }

  function render() {
    if (!host) return;
    var key = trackKey(state);
    var open = !!(state && state.id && state.streamUrl && state.ready !== false && verifiedKey === key);
    var wasOpen = host.classList.contains('gp-open');
    host.classList.toggle('gp-open', open);
    host.classList.toggle('gp-remote', !!(open && state.playing && (!audio || audio.paused)));
    document.body.classList.toggle('ghost-player-visible', open);
    if (open && !wasOpen && window.LiquidGlass && typeof window.LiquidGlass.refresh === 'function') {
      setTimeout(function () { if (host.classList.contains('gp-open')) window.LiquidGlass.refresh(); }, 40);
    }
    if (!open) return;
    var title = host.querySelector('.gp-title');
    var artist = host.querySelector('.gp-artist');
    var now = host.querySelector('.gp-now');
    var art = host.querySelector('.gp-art');
    var placeholder = host.querySelector('.gp-art-placeholder');
    var currentTime = host.querySelector('[data-gp-time="current"]');
    var duration = host.querySelector('[data-gp-time="duration"]');
    var fill = host.querySelector('.gp-progress-fill');
    var play = host.querySelector('[data-gp-action="toggle"]');
    // Shared state drives the icon. A mirror tab must not start a second
    // Audio element merely because another page is playing.
    var actualPlaying = !!state.playing;
    if (title) title.textContent = state.title || 'Без названия';
    if (artist) artist.textContent = state.artist + (state.album ? ' · ' + state.album : '');
    if (now) now.textContent = actualPlaying ? 'NOW PLAYING' : 'PAUSED';
    if (art) art.style.backgroundImage = state.coverUrl ? 'url("' + state.coverUrl.replace(/"/g, '') + '")' : '';
    if (placeholder) placeholder.style.display = state.coverUrl ? 'none' : '';
    var cur = audio && isFinite(audio.currentTime) ? audio.currentTime : state.currentTime;
    var dur = audio && isFinite(audio.duration) && audio.duration > 0 ? audio.duration : state.duration;
    if (currentTime) currentTime.textContent = fmtTime(cur);
    if (duration) duration.textContent = fmtTime(dur);
    if (fill) fill.style.width = (dur > 0 ? Math.max(0, Math.min(100, cur / dur * 100)) : 0) + '%';
    if (play) {
      play.innerHTML = actualPlaying ? iconPause() : iconPlay();
      play.title = actualPlaying ? 'Пауза' : 'Воспроизвести';
      play.setAttribute('aria-label', play.title);
    }
  }

  function applyState(next, remote) {
    var normalized = normalize(next);
    if (!normalized) return;
    var trackChanged = !state || state.streamUrl !== normalized.streamUrl || state.id !== normalized.id;
    if (trackChanged) {
      cancelProbe();
      verifiedKey = '';
      failedKey = '';
    }
    state = normalized;
    if (!booted) return;
    if (trackChanged) disposeAudio();
    if (remote && normalized.owner !== CLIENT_ID) syncRemoteState(normalized);
    verifyTrack(normalized);
    render();
  }

  window.GhostPlayer = {
    version: 1,
    mount: mount,
    publish: publish,
    setTrack: publish,
    getState: function () { return state ? normalize(state) : null; },
    clear: function () {
      state = null;
      cancelProbe();
      verifiedKey = '';
      failedKey = '';
      if (audio) { try { audio.pause(); } catch (e) {} }
      try { localStorage.removeItem(STORAGE_KEY); } catch (e) {}
      if (host) render();
    }
  };

  window.addEventListener('storage', function (event) {
    if (event.key !== STORAGE_KEY || !event.newValue) return;
    try { receiveState(JSON.parse(event.newValue)); } catch (e) {}
  });

  var page = document.body && document.body.getAttribute('data-ghost-player-page');
  if (page && !existingHost) mount({ page: page });
})();
