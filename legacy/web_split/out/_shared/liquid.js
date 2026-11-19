/* ════════════════════════════════════════════════════════════════════
   liquid.js — оживляет жидкое стекло и анимации на сайтах GE
   - IntersectionObserver: добавляет .anim-rise при появлении в viewport
   - MutationObserver: новые узлы тоже анимируются
   - ripple-эффект на любых .glass-btn / [data-ripple]
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
  // 4. Старт
  // -----------------------------------------------------------------
  function start() {
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
