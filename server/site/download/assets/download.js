(function () {
  'use strict';

  var body = document.body;
  var version = body.dataset.downloadVersion;
  var latestPage = body.dataset.latestPage === 'true';
  var localPreview = body.dataset.localPreview === 'true' &&
    /^(localhost|127\.0\.0\.1|::1)$/.test(window.location.hostname);
  var list = document.getElementById('version-list');
  var maintenance = document.getElementById('download-maintenance');
  var releaseCountdownElement = document.getElementById('release-countdown');
  var maintenanceTimer = 0;

  function escapeText(value) {
    return String(value == null ? '' : value);
  }

  function formatSize(bytes) {
    if (!bytes) return '';
    return (bytes / 1024 / 1024).toFixed(1) + ' MB';
  }

  function quickDownload(item, button) {
    button.disabled = true;
    button.textContent = 'Открываю проверку…';
    window.location.assign('/download/v' + encodeURIComponent(item.version) + '/?start=1');
  }

  function showList() {
    if (maintenance) maintenance.hidden = true;
    if (list) list.hidden = false;
  }

  function showMaintenance(iso) {
    if (!maintenance || !releaseCountdownElement || !list) return;
    clearInterval(maintenanceTimer);
    maintenance.hidden = false;
    list.hidden = true;
    var target = Date.parse(iso);
    function render() {
      var left = Number.isFinite(target) ? Math.max(0, target - Date.now()) : 0;
      if (!Number.isFinite(target)) {
        releaseCountdownElement.textContent = 'Дата открытия уточняется…';
        return;
      }
      if (left <= 0) {
        clearInterval(maintenanceTimer);
        showList();
        loadCatalog();
        return;
      }
      var seconds = Math.floor(left / 1000);
      var days = Math.floor(seconds / 86400);
      seconds %= 86400;
      var hours = Math.floor(seconds / 3600);
      seconds %= 3600;
      var minutes = Math.floor(seconds / 60);
      seconds %= 60;
      releaseCountdownElement.textContent = 'До открытия: ' + days + ' дн. ' +
        String(hours).padStart(2, '0') + ':' + String(minutes).padStart(2, '0') + ':' +
        String(seconds).padStart(2, '0');
    }
    render();
    if (Number.isFinite(target)) maintenanceTimer = setInterval(render, 1000);
  }

  function loadCatalog() {
    if (!list) return;
    var catalogUrl = localPreview ? '/api/download/catalog.json' : '/api/download/catalog';
    fetch(catalogUrl, { cache: 'no-store' })
      .then(function (response) { return response.ok ? response.json() : null; })
      .then(function (data) {
        if (!data || !Array.isArray(data.versions)) return;
        var releaseAt = Date.parse(data.release_at);
        if (!data.available && Number.isFinite(releaseAt) && releaseAt > Date.now()) {
          showMaintenance(data.release_at);
          return;
        }
        showList();
        list.textContent = '';
        data.versions.slice().sort(function (left, right) {
          var a = String(left.version || '').split('.').map(Number);
          var b = String(right.version || '').split('.').map(Number);
          for (var index = 0; index < Math.max(a.length, b.length); index += 1) {
            var diff = (b[index] || 0) - (a[index] || 0);
            if (diff) return diff;
          }
          return 0;
        }).forEach(function (item, index) {
          var card = document.createElement('article');
          card.className = index === 0 ? 'version-card version-card-featured' : 'version-card';
          var detailUrl = '/download/v' + encodeURIComponent(item.version) + '/';
          card.addEventListener('click', function (event) {
            if (event.target.closest('.download-card-button')) return;
            window.location.assign(detailUrl);
          });
          card.addEventListener('keydown', function (event) {
            if (event.key === 'Enter' || event.key === ' ') {
              event.preventDefault();
              window.location.assign(detailUrl);
            }
          });
          card.tabIndex = 0;
          var row = document.createElement('div');
          row.className = 'version-card-top';
          var heading = document.createElement('div');
          var kicker = document.createElement('span');
          kicker.className = 'version-kicker';
          kicker.textContent = 'GhostChat · Android APK';
          heading.appendChild(kicker);
          var number = document.createElement('span');
          number.className = 'version-number';
          number.textContent = 'v' + escapeText(item.version);
          heading.appendChild(number);
          row.appendChild(heading);
          if (item.is_latest) {
            var badge = document.createElement('span');
            badge.className = 'badge';
            badge.textContent = 'Новейшая';
            row.appendChild(badge);
          }
          card.appendChild(row);
          var summary = document.createElement('p');
          summary.className = 'card-summary';
          summary.textContent = escapeText(item.notes || item.title || 'Открытая бета GhostChat.');
          card.appendChild(summary);
          var meta = document.createElement('div');
          meta.className = 'card-meta';
          ['Open Beta', 'Android APK', formatSize(item.size)].forEach(function (value) {
            if (!value) return;
            var chip = document.createElement('span');
            chip.className = 'meta-chip';
            chip.textContent = value;
            meta.appendChild(chip);
          });
          card.appendChild(meta);
          var actions = document.createElement('div');
          actions.className = 'card-actions';
          var download = document.createElement('button');
          download.type = 'button';
          download.className = 'download-card-button';
          download.textContent = 'Скачать APK';
          download.addEventListener('click', function (event) {
            event.preventDefault();
            event.stopPropagation();
            quickDownload(item, download);
          });
          actions.appendChild(download);
          var hint = document.createElement('span');
          hint.className = 'card-open-hint';
          hint.textContent = 'Нажми на карточку — открыть детали без автозапуска →';
          actions.appendChild(hint);
          card.appendChild(actions);
          list.appendChild(card);
        });
      })
      .catch(function () {});
  }

  if (!version) {
    loadCatalog();
    return;
  }

  var button = document.getElementById('download-button');
  var status = document.getElementById('download-status');
  var progress = document.querySelector('#download-progress span');
  var captchaPanel = document.getElementById('captcha-panel');
  var captchaImage = document.getElementById('captcha-image');
  var captchaInput = document.getElementById('captcha-input');
  var captchaSubmit = document.getElementById('captcha-submit');
  var captchaRefresh = document.getElementById('captcha-refresh');
  var releaseTimer = document.getElementById('release-timer');
  var gateId = '';
  var captchaId = '';
  var captchaToken = '';
  var captchaRequired = false;
  var localCaptchaAnswer = 'GHOST23';
  var readyToClaim = false;
  var countdownTimer = 0;
  var localFlowStarted = false;

  function setStatus(text, kind) {
    if (!status) return;
    status.textContent = text || '';
    status.dataset.kind = kind || '';
  }

  function parseError(response) {
    return response.json().catch(function () { return {}; }).then(function (data) {
      var detail = data.detail;
      if (detail && typeof detail === 'object') return detail.message || detail.code || 'Не удалось подготовить скачивание';
      return detail || 'Не удалось подготовить скачивание';
    });
  }

  function releaseCountdown(iso) {
    var target = Date.parse(iso);
    if (!releaseTimer || !Number.isFinite(target)) return;
    function render() {
      var left = Math.max(0, target - Date.now());
      if (left <= 0) {
        releaseTimer.textContent = 'Открытая бета доступна — обновите страницу.';
        return;
      }
      var seconds = Math.floor(left / 1000);
      var days = Math.floor(seconds / 86400);
      seconds %= 86400;
      var hours = Math.floor(seconds / 3600);
      seconds %= 3600;
      var minutes = Math.floor(seconds / 60);
      seconds %= 60;
      releaseTimer.textContent = 'До открытия: ' + days + ' дн. ' +
        String(hours).padStart(2, '0') + ':' + String(minutes).padStart(2, '0') + ':' +
        String(seconds).padStart(2, '0');
    }
    render();
    setInterval(render, 1000);
  }

  function loadCaptcha() {
    if (localPreview) {
      captchaPanel.classList.add('is-visible');
      captchaId = 'local-captcha';
      captchaToken = '';
      localCaptchaAnswer = 'GHOST23';
      captchaImage.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(
        '<svg xmlns="http://www.w3.org/2000/svg" width="390" height="112" viewBox="0 0 390 112">' +
          '<rect width="390" height="112" rx="12" fill="#f3efff"/>' +
          '<path d="M0 22L390 84M20 112L350 0M95 0L390 62M0 74L265 0" stroke="#c4b5fd" stroke-width="2" opacity=".65"/>' +
          '<text x="195" y="73" text-anchor="middle" font-family="Arial,sans-serif" font-size="42" font-weight="800" letter-spacing="9" fill="#33205e">GHOST23</text>' +
        '</svg>'
      );
      captchaInput.value = '';
      captchaInput.focus();
      if (captchaSubmit) { captchaSubmit.hidden = false; captchaSubmit.disabled = true; }
      button.hidden = true;
      setStatus('Введите код с картинки, затем нажмите ✓.', '');
      button.disabled = true;
      return Promise.resolve();
    }
    captchaPanel.classList.add('is-visible');
    if (captchaSubmit) { captchaSubmit.hidden = false; captchaSubmit.disabled = true; }
    button.hidden = true;
    setStatus('Высокая нагрузка: введите код с картинки.', '');
    return fetch('/api/bot-check/challenge?purpose=download', { cache: 'no-store' })
      .then(function (response) {
        if (!response.ok) return parseError(response).then(function (message) { throw new Error(message); });
        return response.json();
      })
      .then(function (data) {
        captchaId = data.challenge_id;
        captchaToken = '';
        captchaImage.src = data.image;
        captchaInput.value = '';
        captchaInput.focus();
        if (captchaSubmit) captchaSubmit.disabled = true;
        button.disabled = true;
      });
  }

  function waitFor(seconds) {
    clearInterval(countdownTimer);
    var total = Math.max(1, Number(seconds) || 5);
    var left = total;
    readyToClaim = false;
    button.disabled = true;
    function render() {
      var percent = Math.round((total - left) / total * 100);
      if (progress) progress.style.width = percent + '%';
      setStatus('Подождите ещё ' + left + ' сек.', '');
      if (left <= 0) {
        clearInterval(countdownTimer);
        readyToClaim = true;
        if (localPreview) {
          loadCaptcha().catch(function (error) { setStatus(error.message, 'error'); });
          return;
        }
        if (captchaRequired) {
          loadCaptcha().catch(function (error) { setStatus(error.message, 'error'); });
          return;
        }
        if (captchaId && !captchaToken) {
          setStatus('Введите код CAPTCHA, затем нажмите ✓.', '');
          button.disabled = true;
        } else {
          setStatus('Можно скачивать.', 'ok');
          button.disabled = false;
          button.textContent = 'Скачать GhostChat v' + version;
        }
        return;
      }
      left -= 1;
    }
    render();
    countdownTimer = setInterval(render, 1000);
  }

  function localClaim() {
    var entered = (captchaInput && captchaInput.value || '').trim().toUpperCase();
    if (entered !== localCaptchaAnswer) {
      setStatus('Код CAPTCHA не совпал. Проверьте символы и попробуйте ещё раз.', 'error');
      button.disabled = false;
      if (captchaSubmit) captchaSubmit.disabled = false;
      return;
    }
    button.disabled = true;
    if (captchaSubmit) captchaSubmit.disabled = true;
    button.textContent = 'Скачивание…';
    setStatus('Проверка пройдена. Скачивание начинается…', 'ok');
    var link = document.createElement('a');
    link.href = '/download/apk/GhostChat_V1.1.24ob.apk';
    link.download = 'GhostChat_V1.1.24ob.apk';
    document.body.appendChild(link);
    link.click();
    link.remove();
  }

  function requestClaim() {
    button.disabled = true;
    setStatus('Готовлю одноразовую ссылку…', '');
    fetch('/api/download/claim', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(captchaToken ? { 'X-Ghost-Bot-Token': captchaToken } : {})
      },
      body: JSON.stringify({
        gate_id: gateId,
        version: version,
        bot_token: captchaToken || null
      })
    }).then(function (response) {
      if (!response.ok) return parseError(response).then(function (message) { throw new Error(message); });
      return response.json();
    }).then(function (data) {
      setStatus('Скачивание начинается…', 'ok');
      window.location.assign(data.download_url);
    }).catch(function (error) {
      setStatus(error.message || 'Не удалось начать скачивание.', 'error');
      button.disabled = false;
    });
  }

  function claim() {
    if (localPreview) {
      localClaim();
      return;
    }
    if (!captchaToken && captchaRequired) {
      var solution = (captchaInput && captchaInput.value || '').trim();
      if (!solution) {
        setStatus('Введите код CAPTCHA, затем нажмите ✓.', 'error');
        if (captchaSubmit) captchaSubmit.disabled = false;
        return;
      }
      button.disabled = true;
      setStatus('Проверяю CAPTCHA…', '');
      fetch('/api/bot-check/verify', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ challenge_id: captchaId, solution: solution })
      }).then(function (response) {
        if (!response.ok) return parseError(response).then(function (message) { throw new Error(message); });
        return response.json();
      }).then(function (data) {
        captchaToken = data.bot_token || '';
        if (!captchaToken) throw new Error('CAPTCHA не вернула токен проверки.');
        requestClaim();
    }).catch(function (error) {
      setStatus(error.message || 'Не удалось проверить CAPTCHA.', 'error');
      button.disabled = false;
      if (captchaSubmit) captchaSubmit.disabled = !(captchaInput && captchaInput.value.trim());
      });
      return;
    }
    requestClaim();
  }

  function prepare() {
    if (localPreview) {
      startLocalDownload();
      return;
    }
    button.disabled = true;
    button.textContent = 'Проверяю доступ…';
    setStatus('Проверяю доступность версии…', '');
    fetch('/api/download/prepare', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ version: version })
    }).then(function (response) {
      if (!response.ok) return parseError(response).then(function (message) { throw new Error(message); });
      return response.json();
    }).then(function (data) {
      if (!data.available) {
        button.textContent = 'Скачивание пока закрыто';
        button.disabled = true;
        setStatus('Эта версия станет доступна после открытия беты.', '');
        releaseCountdown(data.release_at);
        return;
      }
      gateId = data.gate_id;
      captchaRequired = !!data.captcha_required;
      button.textContent = 'Ожидание…';
      return waitFor(data.wait_seconds);
    }).catch(function (error) {
      setStatus(error.message || 'Не удалось подготовить скачивание.', 'error');
      button.disabled = false;
      button.textContent = 'Повторить';
    });
  }

  if (captchaInput) {
    captchaInput.addEventListener('input', function () {
      captchaToken = '';
      if (captchaSubmit) captchaSubmit.disabled = !captchaInput.value.trim();
      if (readyToClaim) button.disabled = !captchaInput.value.trim();
    });
  }
  if (captchaSubmit) captchaSubmit.addEventListener('click', function () {
    if (readyToClaim) claim();
  });
  if (captchaRefresh) captchaRefresh.addEventListener('click', function () {
    if (localPreview) {
      loadCaptcha();
    } else {
      loadCaptcha().catch(function (error) { setStatus(error.message, 'error'); });
    }
  });
  if (button) button.addEventListener('click', function () {
    if (readyToClaim) claim();
    else prepare();
  });

  function startLocalDownload() {
    if (localFlowStarted) return;
    localFlowStarted = true;
    button.disabled = true;
    button.textContent = 'Начинаем скачивание…';
    setStatus('Начинаем скачивание. Подождите 10 секунд…', '');
    waitFor(10);
  }

  if (new URLSearchParams(window.location.search).get('start') === '1') {
    if (localPreview) startLocalDownload();
    else prepare();
  }

  if (latestPage) {
    var latestNote = document.querySelector('[data-latest-note]');
    if (latestNote) latestNote.textContent = 'Последняя опубликованная версия GhostChat — v' + version + '.';
  }
})();
