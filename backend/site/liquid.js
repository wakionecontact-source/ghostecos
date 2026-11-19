/* ════════════════════════════════════════════════════════════════════
   liquid.js — оживляет жидкое стекло и анимации на сайтах GE
   - IntersectionObserver: добавляет .anim-rise при появлении в viewport
   - MutationObserver: новые узлы тоже анимируются
   - ripple-эффект на любых .glass-btn / [data-ripple]
   - вложенная матовая метка через .glass-label-matte или data-glass-matte-label
   - reduce-motion respect через media query (CSS уже это делает)
   ════════════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  if (window.__LIQUID_LOADED__) return;
  window.__LIQUID_LOADED__ = true;

  // -----------------------------------------------------------------
  // 1. Auto-rise: всё с [data-anim] анимируется при появлении
  // -----------------------------------------------------------------
  var io = ('IntersectionObserver' in window) ? new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      if (e.isIntersecting) {
        var t = e.target;
        var cls = t.getAttribute('data-anim') || 'anim-rise';
        // re-trigger даже если уже было
        t.classList.remove(cls);
        // force reflow
        void t.offsetWidth;
        t.classList.add(cls);
        io.unobserve(t);
      }
    });
  }, { rootMargin: '0px 0px -10% 0px', threshold: 0.05 }) : null;

  // Селекторы типовых элементов, которым нужна анимация появления.
  // Можно расширять локально через window.LIQUID_AUTO_SEL = '...'
  // или отключить через window.LIQUID_AUTO_SEL = '' до загрузки liquid.js.
  var AUTO_SEL = (typeof window.LIQUID_AUTO_SEL === 'string')
    ? window.LIQUID_AUTO_SEL
    : [
        '.msg', '.message', '.bubble',
        '.post', '.feed-item', '.feed-card',
        '.notif', '.notif-item', '.notification',
        '.dialog-item', '.chat-item', '.contact-item',
        '.channel-item', '.channel-card',
        '.nft-card', '.nft-tile',
        '.tx-row', '.wallet-row', '.transaction',
        '.comment', '.reply',
        '.miniska', '.miniska-card',
        '.modal-content', '.dialog-content',
        '.tab-content',
      ].join(',');

  function autoTagAnim(root) {
    if (!AUTO_SEL) return;
    var nodes = (root || document).querySelectorAll(AUTO_SEL);
    nodes.forEach(function (el) {
      if (!el.hasAttribute('data-anim')) {
        el.setAttribute('data-anim', 'anim-rise-flat');
      }
    });
  }

  function observe(root) {
    if (!io) return;
    // Сначала навешиваем data-anim на типовые элементы,
    // потом наблюдаем все [data-anim].
    autoTagAnim(root);
    var nodes = (root || document).querySelectorAll('[data-anim]:not([data-anim-done])');
    nodes.forEach(function (n) {
      n.setAttribute('data-anim-done', '1');
      io.observe(n);
    });
  }

  // -----------------------------------------------------------------
  // 2. MutationObserver — новые сообщения/посты тоже получают анимацию
  // -----------------------------------------------------------------
  var mo = ('MutationObserver' in window) ? new MutationObserver(function (mutations) {
    mutations.forEach(function (m) {
      m.addedNodes.forEach(function (n) {
        if (n.nodeType !== 1) return;
        if (n.matches && n.matches('[data-anim]')) {
          n.setAttribute('data-anim-done', '1');
          io && io.observe(n);
        }
        observe(n);
      });
    });
  }) : null;

  // -----------------------------------------------------------------
  // 3. Ripple: клик на .glass-btn / [data-ripple] оставляет волну
  // -----------------------------------------------------------------
  function ripple(ev) {
    var el = ev.currentTarget;
    var rect = el.getBoundingClientRect();
    var r = document.createElement('span');
    r.className = '_lq_ripple';
    var sz = Math.max(rect.width, rect.height) * 1.4;
    r.style.cssText =
      'position:absolute;border-radius:50%;pointer-events:none;' +
      'width:' + sz + 'px;height:' + sz + 'px;' +
      'left:' + (ev.clientX - rect.left - sz / 2) + 'px;' +
      'top:' + (ev.clientY - rect.top - sz / 2) + 'px;' +
      'background:radial-gradient(circle, rgba(255,255,255,0.35) 0%, rgba(255,255,255,0) 70%);' +
      'transform:scale(0);opacity:1;' +
      'animation:_lq_ripple_anim 620ms cubic-bezier(0.16,1,0.3,1) forwards;';
    var pos = window.getComputedStyle(el).position;
    if (pos === 'static') el.style.position = 'relative';
    var prevOverflow = el.style.overflow;
    el.style.overflow = 'hidden';
    el.appendChild(r);
    setTimeout(function () {
      r.remove();
      if (!el.querySelector('._lq_ripple')) el.style.overflow = prevOverflow;
    }, 700);
  }

  function bindRipples(root) {
    var nodes = (root || document).querySelectorAll('.glass-btn, [data-ripple]');
    nodes.forEach(function (n) {
      if (n.__lq_ripple_bound) return;
      n.__lq_ripple_bound = true;
      n.addEventListener('pointerdown', ripple);
    });
  }

  // inject ripple keyframes если ещё нет
  if (!document.getElementById('_lq_kf')) {
    var style = document.createElement('style');
    style.id = '_lq_kf';
    style.textContent =
      '@keyframes _lq_ripple_anim{to{transform:scale(1);opacity:0;}}';
    document.head.appendChild(style);
  }

  // 5. Мелкий SVG-refraction для маленьких pill-элементов (.algo-chip,
  //    .filter-btn). На КРУПНЫХ карточках displacement лагает; на pill-ах
  //    их немного и GPU справляется — это даёт настоящее «iOS lensing»
  //    по краям как в Apple Liquid Glass.
  if (!document.getElementById('lq-pill-filter')) {
    var svgNS = 'http://www.w3.org/2000/svg';
    var svg = document.createElementNS(svgNS, 'svg');
    svg.setAttribute('width', '0');
    svg.setAttribute('height', '0');
    svg.setAttribute('aria-hidden', 'true');
    svg.style.cssText = 'position:absolute;width:0;height:0;overflow:hidden;';
    svg.innerHTML =
      '<defs>' +
        '<filter id="lq-pill-filter" x="-10%" y="-10%" width="120%" height="120%">' +
          // плавная карта высот — без шума, чистая линза от центра к краям
          '<feTurbulence type="fractalNoise" baseFrequency="0.015 0.015" ' +
            'numOctaves="1" seed="42" result="noise"/>' +
          '<feDisplacementMap in="SourceGraphic" in2="noise" scale="8" ' +
            'xChannelSelector="R" yChannelSelector="G"/>' +
        '</filter>' +
      '</defs>';
    (document.body || document.documentElement).insertBefore(
      svg, (document.body || document.documentElement).firstChild
    );
  }

  // -----------------------------------------------------------------
  // 6. LIQUID GLASS ENGINE — SVG-рефракция с feDisplacementMap
  //    Вынесен из index.html, теперь конфигурируется через
  //    window.LIQUID_GLASS_SEL. Селектор подставляется перед загрузкой.
  //    backdrop-filter: url(...) не работает в браузерах на
  //    современных версиях, но визуальный specular-блик даёт CSS.
  // -----------------------------------------------------------------
  (function () {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

    var GLASS_LABEL_SEL = '.glass-label, .glass-label-matte';
    var GLASS_ENGINE_SEL = '[data-liquid-glass]';
    var customGlassSel = (typeof window.LIQUID_GLASS_SEL === 'string' && window.LIQUID_GLASS_SEL)
      ? window.LIQUID_GLASS_SEL
      : '';
    var GLASS_SEL = customGlassSel
      ? customGlassSel + ', ' + GLASS_LABEL_SEL + ', ' + GLASS_ENGINE_SEL
      : '.feature-card, .crypto-card, .crypto-visual, .platform-card, ' +
        '.premium-price-card, .premium-features-card, .btn-lq, .nav-btn-lq, ' + GLASS_LABEL_SEL + ', ' + GLASS_ENGINE_SEL;

    if (!GLASS_SEL) return;

    function lensMap(h, w, r, d) {
      var pY = Math.ceil((r / h * 100) || 0);
      var pX = Math.ceil((r / w * 100) || 0);
      return 'data:image/svg+xml;utf8,' + encodeURIComponent(
        '<svg height="' + h + '" width="' + w + '" viewBox="0 0 ' + w + ' ' + h + '" xmlns="http://www.w3.org/2000/svg">' +
        '<style>.m{mix-blend-mode:screen}</style>' +
        '<defs>' +
          '<linearGradient id="Y" x1="0" x2="0" y1="' + pY + '%" y2="' + (100 - pY) + '%">' +
            '<stop offset="0%" stop-color="#0F0"/>' +
            '<stop offset="50%" stop-color="#000"/>' +
            '<stop offset="100%" stop-color="#0F0"/>' +
          '</linearGradient>' +
          '<linearGradient id="X" x1="' + pX + '%" x2="' + (100 - pX) + '%" y1="0" y2="0">' +
            '<stop offset="0%" stop-color="#F00"/>' +
            '<stop offset="50%" stop-color="#000"/>' +
            '<stop offset="100%" stop-color="#F00"/>' +
          '</linearGradient>' +
        '</defs>' +
        '<rect width="' + w + '" height="' + h + '" fill="#808080"/>' +
        '<g filter="blur(2px)">' +
          '<rect width="' + w + '" height="' + h + '" fill="#000080"/>' +
          '<rect width="' + w + '" height="' + h + '" fill="url(#Y)" class="m"/>' +
          '<rect width="' + w + '" height="' + h + '" fill="url(#X)" class="m"/>' +
          '<rect x="' + (d * 0.5) + '" y="' + (d * 0.5) + '" height="' + (h - d) + '" width="' + (w - d) + '" fill="#808080" rx="' + r + '" ry="' + r + '" filter="blur(' + (d * 0.7) + 'px)" opacity=".85"/>' +
          '<rect x="' + d + '" y="' + d + '" height="' + (h - 2 * d) + '" width="' + (w - 2 * d) + '" fill="#808080" rx="' + r + '" ry="' + r + '" filter="blur(' + d + 'px)"/>' +
        '</g></svg>');
    }

    var _cache = {};
    function filterUrl(h, w, r, d, scale) {
      var k = [h, w, Math.round(r), Math.round(d), scale].join('|');
      if (_cache[k]) return _cache[k];
      var map = lensMap(h, w, r, d);
      var u = 'data:image/svg+xml;utf8,' + encodeURIComponent(
        '<svg height="' + h + '" width="' + w + '" viewBox="0 0 ' + w + ' ' + h + '" xmlns="http://www.w3.org/2000/svg">' +
        '<defs><filter id="lg" color-interpolation-filters="sRGB">' +
        '<feImage x="0" y="0" height="' + h + '" width="' + w + '" href="' + map + '" result="map"/>' +
        '<feDisplacementMap in="SourceGraphic" in2="map" scale="' + scale + '" xChannelSelector="R" yChannelSelector="G"/>' +
        '</filter></defs></svg>') + '#lg';
      _cache[k] = u;
      return u;
    }

    function batch(n) { return Math.round(n / 8) * 8; }

    function apply(el, force) {
      var r = el.getBoundingClientRect();
      var w = batch(r.width), h = batch(r.height);
      if (w < 10 || h < 10) return;
      var rad = batch(parseFloat(getComputedStyle(el).borderRadius) || 0);
      var dp = Math.max(8, batch(Math.min(w, h) * 0.1));
      var sig = [w, h, rad, dp, 75].join('|');
      if (!force && sig === el.dataset.sig) return;
      el.dataset.sig = sig;
      var glassFilter = "url('" + filterUrl(h, w, rad, dp, 75) + "')";
      var isGlassLabel = el.matches && el.matches(GLASS_LABEL_SEL);
      var filterValue = isGlassLabel
        ? 'blur(14px) saturate(120%) ' + glassFilter
        : glassFilter;
      // GhoSou has a final glass layer with !important blur declarations.
      // Keep the homepage's real SVG refraction filter as the winning layer.
      el.style.setProperty('backdrop-filter', filterValue, 'important');
      el.style.setProperty('-webkit-backdrop-filter', filterValue, 'important');
    }

    function init() {
      document.querySelectorAll(GLASS_SEL).forEach(function (el) { apply(el, true); });
    }

    init();

    // Cards and panels in GhoSou are rendered after the initial page load.
    // Refresh only when a newly inserted node can contain a glass surface.
    var _glassMutationTimer;
    var glassMo = ('MutationObserver' in window) ? new MutationObserver(function (mutations) {
      var shouldRefresh = false;
      mutations.forEach(function (m) {
        m.addedNodes.forEach(function (n) {
          if (n.nodeType !== 1) return;
          enhanceMatteLabels(n);
          try {
            if ((n.matches && n.matches(GLASS_SEL)) || (n.querySelector && n.querySelector(GLASS_SEL))) shouldRefresh = true;
          } catch (e) {}
        });
      });
      if (!shouldRefresh) return;
      clearTimeout(_glassMutationTimer);
      _glassMutationTimer = setTimeout(function () {
        document.querySelectorAll(GLASS_SEL).forEach(function (el) { delete el.dataset.sig; apply(el, true); });
      }, 90);
    }) : null;
    if (glassMo && document.body) glassMo.observe(document.body, { childList: true, subtree: true });

    var _rt;
    addEventListener('resize', function () {
      clearTimeout(_rt);
      _rt = setTimeout(function () { document.querySelectorAll(GLASS_SEL).forEach(function (el) { delete el.dataset.sig; apply(el, true); }); }, 200);
    }, { passive: true });

    window.LiquidGlass = {
      apply: apply,
      addMatteLabel: addMatteLabel,
      refresh: function () {
        document.querySelectorAll(GLASS_SEL).forEach(function (el) { delete el.dataset.sig; apply(el, true); });
      },
    };
  })();

  function resolveGlassElement(target) {
    if (typeof target === 'string') return document.querySelector(target);
    return target && target.nodeType === 1 ? target : null;
  }

  // Добавляет вторую, матовую метку внутрь существующего label.
  // Пример: LiquidGlass.addMatteLabel('.status-label', 'NEW');
  function addMatteLabel(target, text, options) {
    var host = resolveGlassElement(target);
    if (!host) return null;
    var opts = options || {};
    var badge = document.createElement('span');
    badge.className = 'glass-label-matte';
    badge.textContent = text == null ? '' : String(text);
    host.classList.add('glass-label');
    if (opts.position === 'overlay') host.classList.add('glass-label--overlay');
    if (opts.className) {
      String(opts.className).split(/\s+/).filter(Boolean).forEach(function (name) {
        badge.classList.add(name);
      });
    }
    host.appendChild(badge);
    setTimeout(function () {
      if (window.LiquidGlass && window.LiquidGlass.refresh) window.LiquidGlass.refresh();
    }, 0);
    return badge;
  }

  // Декларативный вариант:
  // <span data-glass-matte-label="NEW">Статус</span>
  function enhanceMatteLabels(root) {
    var scope = root || document;
    var nodes = [];
    if (scope.matches && scope.matches('[data-glass-matte-label]')) nodes.push(scope);
    if (scope.querySelectorAll) {
      scope.querySelectorAll('[data-glass-matte-label]').forEach(function (el) { nodes.push(el); });
    }
    nodes.forEach(function (el) {
      if (el.__lq_matte_label_bound) return;
      var text = el.getAttribute('data-glass-matte-label');
      if (!text) return;
      el.__lq_matte_label_bound = true;
      addMatteLabel(el, text, { position: el.getAttribute('data-glass-matte-position') });
    });
  }

  if (window.LiquidGlass) {
    window.LiquidGlass.addMatteLabel = addMatteLabel;
  } else {
    window.LiquidGlass = { addMatteLabel: addMatteLabel, refresh: function () {} };
  }

  // -----------------------------------------------------------------
  // 4. Старт
  // -----------------------------------------------------------------
  function start() {
    enhanceMatteLabels(document);
    observe(document);
    bindRipples(document);
    if (mo) mo.observe(document.body, { childList: true, subtree: true });
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }

  // Публичный API — если нужно вручную перевызвать
  window.LiquidUI = {
    observe: observe,
    bindRipples: bindRipples,
    // ручной запуск анимации на узле
    play: function (el, cls) {
      if (!el) return;
      cls = cls || 'anim-rise';
      el.classList.remove(cls);
      void el.offsetWidth;
      el.classList.add(cls);
    },
  };
})();
