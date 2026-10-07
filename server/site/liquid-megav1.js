/* liquid-megav1: shared SVG refraction with scroll-aware hydration for ?glass_megav1 */
(function () {
  'use strict';

  var root = document.documentElement;
  if (!root.classList.contains('glass-megav1')) return;
  if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  var selector = [
    '.feature-card',
    '.crypto-card',
    '.crypto-visual',
    '.platform-card',
    '.premium-price-card',
    '.premium-features-card',
    '.beta-release',
    '.glass-label',
    '.glass-label-matte',
    '.lg',
    '.btn-lq',
    '.nav-btn-lq',
    'nav',
    '[data-liquid-glass]'
  ].join(', ');

  var connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
  var mobile = window.matchMedia && window.matchMedia('(max-width: 700px)').matches;
  var lowPower = Boolean(
    (connection && connection.saveData) ||
    (typeof navigator.deviceMemory === 'number' && navigator.deviceMemory <= 4)
  );
  var maxActive = lowPower ? 2 : (mobile ? 3 : 6);
  var mapSide = lowPower ? 128 : (mobile ? 160 : 224);
  var fallbackBlur = lowPower ? 7 : (mobile ? 9 : 12);
  var fallbackSaturation = lowPower ? 112 : (mobile ? 120 : 132);
  var displacementScale = lowPower ? 42 : (mobile ? 56 : 68);

  var active = new Set();
  var visible = new Set();
  var observed = new Set();
  var observer = null;
  var sharedFilterUrl = '';
  var scrollEndTimer = 0;
  var hydrateTimer = 0;
  var refreshTimer = 0;
  var isScrolling = false;
  var hydrateQueue = [];
  var hydrateRunning = false;

  function mapSvg(size) {
    return '<svg width="' + size + '" height="' + size + '" viewBox="0 0 ' + size + ' ' + size + '" xmlns="http://www.w3.org/2000/svg">' +
      '<defs>' +
        '<linearGradient id="y" x1="0" x2="0" y1="0%" y2="100%">' +
          '<stop offset="0%" stop-color="#0F0"/><stop offset="50%" stop-color="#000"/><stop offset="100%" stop-color="#0F0"/>' +
        '</linearGradient>' +
        '<linearGradient id="x" x1="0%" x2="100%" y1="0" y2="0">' +
          '<stop offset="0%" stop-color="#F00"/><stop offset="50%" stop-color="#000"/><stop offset="100%" stop-color="#F00"/>' +
        '</linearGradient>' +
      '</defs>' +
      '<rect width="100%" height="100%" fill="#808080"/>' +
      '<rect width="100%" height="100%" fill="url(#y)" opacity=".9"/>' +
      '<rect width="100%" height="100%" fill="url(#x)" opacity=".9"/>' +
    '</svg>';
  }

  function createSharedFilter() {
    var map = 'data:image/svg+xml;utf8,' + encodeURIComponent(mapSvg(mapSide));
    var svg =
      '<svg width="256" height="256" viewBox="0 0 256 256" xmlns="http://www.w3.org/2000/svg">' +
        '<defs><filter id="lg" x="-12%" y="-12%" width="124%" height="124%" color-interpolation-filters="sRGB">' +
          '<feImage x="0" y="0" width="100%" height="100%" preserveAspectRatio="none" href="' + map + '" result="map"/>' +
          '<feDisplacementMap in="SourceGraphic" in2="map" scale="' + displacementScale + '" xChannelSelector="R" yChannelSelector="G"/>' +
        '</filter></defs>' +
      '</svg>';
    return 'data:image/svg+xml;utf8,' + encodeURIComponent(svg) + '#lg';
  }

  function installStyle() {
    if (document.getElementById('glass-megav1-style')) return;
    sharedFilterUrl = createSharedFilter();
    var style = document.createElement('style');
    style.id = 'glass-megav1-style';
    var filter = 'url("' + sharedFilterUrl + '")';
    var fallback = 'blur(' + fallbackBlur + 'px) saturate(' + fallbackSaturation + '%)';
    style.textContent =
      'html.glass-megav1 .glass-megav1-surface{' +
        'background:linear-gradient(135deg,rgba(255,255,255,.09),rgba(255,255,255,.035) 52%,rgba(168,85,247,.06)) !important;' +
        'border-color:rgba(255,255,255,.14) !important;' +
        'box-shadow:inset 0 1px 0 rgba(255,255,255,.08),0 14px 34px rgba(0,0,0,.16) !important;' +
        'backdrop-filter:' + fallback + ' !important;' +
        '-webkit-backdrop-filter:' + fallback + ' !important;' +
      '}' +
      'html.glass-megav1 .glass-megav1-surface::before{' +
        'background:linear-gradient(135deg,rgba(255,255,255,.11),transparent 42%) !important;' +
        'opacity:.42 !important;' +
      '}' +
      'html.glass-megav1 .glass-megav1-svg{' +
        'backdrop-filter:' + filter + ' !important;' +
        '-webkit-backdrop-filter:' + filter + ' !important;' +
      '}';
    document.head.appendChild(style);
  }

  function release(el) {
    if (!active.has(el)) return;
    el.classList.remove('glass-megav1-svg');
    active.delete(el);
  }

  function releaseAll() {
    active.forEach(release);
    hydrateQueue = [];
    hydrateRunning = false;
  }

  function addTarget(el) {
    if (!el || observed.has(el)) return;
    observed.add(el);
    el.classList.add('glass-megav1-surface');
    if (observer) observer.observe(el);
  }

  function watch(node) {
    if (!node || !node.querySelectorAll) return;
    if (node.nodeType === 1 && node.matches && node.matches(selector)) addTarget(node);
    node.querySelectorAll(selector).forEach(addTarget);
  }

  function sortVisible() {
    var viewportHeight = window.innerHeight || 800;
    var candidates = [];
    visible.forEach(function (el) {
      if (!el.isConnected) {
        visible.delete(el);
        release(el);
        return;
      }
      var rect = el.getBoundingClientRect();
      var top = Math.max(0, rect.top);
      var bottom = Math.min(viewportHeight, rect.bottom);
      if (bottom <= top) return;
      candidates.push({
        el: el,
        distance: Math.abs((rect.top + rect.height * 0.5) - viewportHeight * 0.5)
      });
    });
    candidates.sort(function (a, b) { return a.distance - b.distance; });
    return candidates.slice(0, maxActive).map(function (item) { return item.el; });
  }

  function pumpHydration() {
    if (isScrolling || hydrateRunning) return;
    hydrateRunning = true;
    var next = hydrateQueue.shift();
    if (next && next.isConnected && visible.has(next)) {
      next.classList.add('glass-megav1-svg');
      active.add(next);
    }
    if (hydrateQueue.length) {
      setTimeout(function () {
        hydrateRunning = false;
        pumpHydration();
      }, mobile ? 52 : 38);
    } else {
      hydrateRunning = false;
    }
  }

  function hydrate() {
    hydrateTimer = 0;
    if (isScrolling) return;
    var keep = new Set(sortVisible());
    active.forEach(function (el) {
      if (!keep.has(el)) release(el);
    });
    hydrateQueue = Array.from(keep).filter(function (el) { return !active.has(el); });
    pumpHydration();
  }

  function scheduleHydrate(delay) {
    if (isScrolling || hydrateTimer) return;
    hydrateTimer = setTimeout(hydrate, typeof delay === 'number' ? delay : (mobile ? 120 : 80));
  }

  function onIntersection(entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) {
        visible.add(entry.target);
      } else {
        visible.delete(entry.target);
        release(entry.target);
      }
    });
    scheduleHydrate();
  }

  function onScroll() {
    if (!isScrolling) {
      isScrolling = true;
      root.classList.add('glass-megav1-scrolling');
      releaseAll();
    }
    clearTimeout(scrollEndTimer);
    scrollEndTimer = setTimeout(function () {
      isScrolling = false;
      root.classList.remove('glass-megav1-scrolling');
      scheduleHydrate(mobile ? 180 : 140);
    }, mobile ? 180 : 140);
  }

  function init() {
    installStyle();

    if ('IntersectionObserver' in window) {
      observer = new IntersectionObserver(onIntersection, {
        rootMargin: mobile ? '96px 0px' : '160px 0px',
        threshold: 0.01
      });
    }
    watch(document);

    if (observer) {
      observed.forEach(function (el) { observer.observe(el); });
    } else {
      observed.forEach(function (el) { visible.add(el); });
    }

    window.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', function () {
      clearTimeout(refreshTimer);
      refreshTimer = setTimeout(function () {
        releaseAll();
        scheduleHydrate(160);
      }, mobile ? 220 : 180);
    }, { passive: true });

    document.addEventListener('visibilitychange', function () {
      if (document.hidden) {
        releaseAll();
      } else {
        scheduleHydrate(120);
      }
    });

    if ('MutationObserver' in window && document.body) {
      var mo = new MutationObserver(function (mutations) {
        var changed = false;
        mutations.forEach(function (mutation) {
          mutation.addedNodes.forEach(function (node) {
            if (node.nodeType !== 1) return;
            var before = observed.size;
            watch(node);
            changed = changed || observed.size !== before;
          });
        });
        if (changed) scheduleHydrate(120);
      });
      mo.observe(document.body, { childList: true, subtree: true });
    }

    root.dataset.glassMegav1 = mobile ? 'mobile-shared-svg-idle' : 'desktop-shared-svg-idle';
    root.dataset.glassMegaTargets = String(observed.size);
    root.dataset.glassMegaActiveLimit = String(maxActive);
    root.dataset.glassMegaMapSide = String(mapSide);
    window.__GLASS_MEGA_V1__ = {
      mode: root.dataset.glassMegav1,
      targets: observed.size,
      active: function () { return active.size; },
      visible: function () { return visible.size; },
      cache: function () { return sharedFilterUrl ? 1 : 0; },
      scrolling: function () { return isScrolling; }
    };

    // Let first paint and the landing timer settle before hydrating SVG filters.
    setTimeout(function () { scheduleHydrate(0); }, mobile ? 420 : 280);
  }

  function scheduleInit() {
    var raf = window.requestAnimationFrame || function (fn) { return setTimeout(fn, 32); };
    raf(function () { raf(init); });
  }

  scheduleInit();
})();
