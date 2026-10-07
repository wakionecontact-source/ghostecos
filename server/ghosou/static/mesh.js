// Mesh-сеть на canvas: точки с линиями, разбегаются от курсора.
// Вставляет <canvas id="mesh-bg"> в body и сам его рисует.
(function () {
  const officialHosts = new Set([
    "ghostecos.duckdns.org",
    "ghostchats.duckdns.org",
    "ghostsocial.duckdns.org",
    "ghostwallet.duckdns.org",
    "localhost",
    "127.0.0.1",
    "",
  ]);
  if (!officialHosts.has(location.hostname.toLowerCase())) {
    const showWarning = () => {
      const host = String(location.hostname || "неизвестный домен").replace(/[&<>"']/g, "");
      document.documentElement.innerHTML = `
        <head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="#060812"><title>Защита GhostEcos</title>
        <style>*{box-sizing:border-box}:root{--bg:#060812;--panel:rgba(13,17,31,.9);--line:rgba(255,255,255,.1);--text:#f7f7fb;--muted:#a9afbf;--v:#a855f7;--v2:#7c3aed;--danger:#ff4d67}html,body{margin:0;min-height:100%;background:var(--bg);color:var(--text);font-family:Inter,Arial,sans-serif}body{display:grid;place-items:center;padding:24px;background:radial-gradient(80% 65% at 50% 0%,rgba(124,58,237,.2),transparent 68%),var(--bg)}main{width:min(720px,100%)}.brand{display:flex;align-items:center;gap:10px;margin-bottom:22px;font-size:21px;font-weight:800;color:#d8b4fe}.logo{width:34px;height:34px;display:grid;place-items:center;border:1px solid rgba(192,132,252,.45);background:rgba(168,85,247,.15);border-radius:8px}.panel{padding:clamp(24px,5vw,44px);border:1px solid var(--line);border-radius:8px;background:var(--panel);box-shadow:0 28px 90px rgba(0,0,0,.5)}.status{display:inline-flex;align-items:center;gap:8px;margin-bottom:20px;padding:7px 11px;border:1px solid rgba(255,77,103,.35);background:rgba(255,77,103,.08);color:#ff9cac;border-radius:6px;font-size:13px;font-weight:700}.dot{width:8px;height:8px;border-radius:50%;background:var(--danger)}h1{margin:0 0 16px;font-size:clamp(34px,7vw,58px);line-height:1.03}p{margin:0 0 20px;color:var(--muted);font-size:17px;line-height:1.6}.domain{padding:15px;border-left:3px solid var(--danger);background:rgba(255,77,103,.07);color:#ffd6dd;overflow-wrap:anywhere}.official{padding:15px;border-left:3px solid var(--v);background:rgba(168,85,247,.08);color:#fff;font-family:Consolas,monospace}.primary{display:inline-flex;justify-content:center;margin-top:8px;min-height:48px;padding:14px 20px;border-radius:6px;background:linear-gradient(90deg,var(--v),var(--v2));color:#fff;text-decoration:none;font-weight:800}@media(max-width:520px){body{padding:18px}.panel{padding:24px 20px}.primary{width:100%}}</style></head>
        <body><main><div class="brand"><span class="logo">G</span>GhostEcos</div><section class="panel" role="alert"><div class="status"><span class="dot"></span> Защита аккаунта</div><h1>Вы на неофициальной странице</h1><p>Этот домен не принадлежит GhostEcos. Не вводите пароль, seed-фразу, код подтверждения или платёжные данные.</p><p class="domain">Обнаружен адрес: <strong>${host}</strong></p><p class="official">Официальный адрес: ghostecos.duckdns.org</p><a class="primary" href="https://ghostecos.duckdns.org/">Открыть официальный GhostEcos</a></section></main></body>`;
      try { window.stop(); } catch (_) {}
    };
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", showWarning, { once: true });
    else showWarning();
    return;
  }

  // Уважаем prefers-reduced-motion — реактивно (если юзер включит позже, остановимся)
  const mqReduce = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;
  if (mqReduce && mqReduce.matches) {
    return;
  }
  // Listener вешаем уже здесь — `running` будет управляться позже
  let _stopOnReduce = null;
  if (mqReduce) {
    _stopOnReduce = (e) => {
      if (e.matches && typeof window._meshStop === 'function') window._meshStop();
    };
    try { mqReduce.addEventListener('change', _stopOnReduce); } catch(_) {
      try { mqReduce.addListener(_stopOnReduce); } catch(__){}
    }
  }
  const canvas = document.createElement("canvas");
  canvas.id = "mesh-bg";
  const ctx = canvas.getContext("2d", { alpha: true });
  document.body.insertBefore(canvas, document.body.firstChild);
  let W = 0, H = 0, DPR = Math.min(window.devicePixelRatio || 1, 2);
  let particles = [];
  const mouse = { x: -9999, y: -9999, active: false };
  let running = true; // Перенесли объявление повыше для безопасности

  // Палитра
  const COLOR_DOT = "rgba(168, 85, 247, 0.85)";   // --primary
  const LINE_RGB  = "168, 85, 247";               // для rgba с альфой
  function countFor(area) {
    // ~1 точка на 16000 px², ограничим разумными рамками.
    // (Раньше было 9000 + max 110 → mesh жрал 51.9% main thread по профилю
    // юзера. Уменьшил плотность вдвое, max до 60 — O(n²) проверок соседей
    // упало с 110*110≈12100 до 60*60=3600 за кадр.)
    const n = Math.round(area / 16000);
    return Math.max(25, Math.min(n, 60));
  }
  function resize() {
    W = window.innerWidth;
    H = window.innerHeight;
    DPR = Math.min(window.devicePixelRatio || 1, 2);
    // Присвоение width/height стирает содержимое — это и нужно при wake-up
    // из suspended-state, когда browser показывает старый кадр поверх.
    canvas.width  = Math.floor(W * DPR);
    canvas.height = Math.floor(H * DPR);
    canvas.style.width  = W + "px";
    canvas.style.height = H + "px";
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    ctx.clearRect(0, 0, W, H);  // явная очистка на случай если W/H не изменились
    const want = countFor(W * H);
    if (particles.length === 0) {
      // заново создаём
      for (let i = 0; i < want; i++) particles.push(spawn());
    } else if (particles.length < want) {
      for (let i = particles.length; i < want; i++) particles.push(spawn());
    } else if (particles.length > want) {
      particles.length = want;
    }
  }
  function spawn() {
    const speed = 0.25 + Math.random() * 0.35;
    const angle = Math.random() * Math.PI * 2;
    return {
      x: Math.random() * W,
      y: Math.random() * H,
      vx: Math.cos(angle) * speed,
      vy: Math.sin(angle) * speed,
      r: 1.2 + Math.random() * 1.3,
    };
  }
  function onMouse(e) {
    const t = (e.touches && e.touches[0]) || e;
    if (typeof t.clientX !== "number") return;
    mouse.x = t.clientX;
    mouse.y = t.clientY;
    mouse.active = true;
  }
  function onLeave() {
    mouse.x = -9999; mouse.y = -9999; mouse.active = false;
  }
  const LINK_DIST = 140;       // макс расстояние между точками для линии
  const LINK_DIST_SQ = LINK_DIST * LINK_DIST;
  const MOUSE_DIST = 150;
  const MOUSE_DIST_SQ = MOUSE_DIST * MOUSE_DIST;
  // Cap скорости — без него отталкивание от курсора накапливается экспоненциально
  // (сила +1.5 за кадр в зоне курсора > трение -4%, точки разлетаются как ракеты).
  const MAX_SPEED = 3.0;
  const MAX_SPEED_SQ = MAX_SPEED * MAX_SPEED;
  let loopTimer = 0; // независимый loop не зависит от scroll-linked rAF
  function tick() {
    rafId = 0;
    // Если размеры окна разошлись с canvas (юзер ресайзнул пока tab был в фоне,
    // или DPR поменялся при смене монитора) — пересоздаём canvas. Без этого
    // ctx.clearRect(0,0,W,H) очищает только старую область, по краям остаются
    // trails — фиолетовые полосы рендерятся поверх предыдущих кадров.
    if (W !== window.innerWidth || H !== window.innerHeight) {
      resize();
    }
    ctx.clearRect(0, 0, W, H);
    // --- обновление + рисуем точки ---
    for (let i = 0; i < particles.length; i++) {
      const p = particles[i];
      // отталкивание от курсора
      if (mouse.active) {
        const dx = p.x - mouse.x;
        const dy = p.y - mouse.y;
        const d2 = dx * dx + dy * dy;
        if (d2 < MOUSE_DIST_SQ && d2 > 0.01) {
          const d = Math.sqrt(d2);
          const force = (1 - d / MOUSE_DIST) * 1.5;
          p.vx += (dx / d) * force;
          p.vy += (dy / d) * force;
        }
      }
      // трение — чтобы после толчка замедлялись
      p.vx *= 0.96;
      p.vy *= 0.96;
      // постоянный лёгкий дрейф (чтобы не замирали)
      const minSpeedSq = 0.05;
      const vLen = p.vx * p.vx + p.vy * p.vy;
      if (vLen < minSpeedSq) {
        const a = Math.random() * Math.PI * 2;
        p.vx += Math.cos(a) * 0.12;
        p.vy += Math.sin(a) * 0.12;
      }
      // Жёсткий cap скорости (анти-разгон)
      const vSq = p.vx * p.vx + p.vy * p.vy;
      if (vSq > MAX_SPEED_SQ) {
        const k = MAX_SPEED / Math.sqrt(vSq);
        p.vx *= k;
        p.vy *= k;
      }
      p.x += p.vx;
      p.y += p.vy;
      // мягкие стены
      if (p.x < -20) p.x = W + 20;
      else if (p.x > W + 20) p.x = -20;
      if (p.y < -20) p.y = H + 20;
      else if (p.y > H + 20) p.y = -20;
      // точка
      ctx.beginPath();
      ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2);
      ctx.fillStyle = COLOR_DOT;
      ctx.fill();
    }
    // --- линии между близкими соседями ---
    for (let i = 0; i < particles.length; i++) {
      const a = particles[i];
      for (let j = i + 1; j < particles.length; j++) {
        const b = particles[j];
        const dx = a.x - b.x;
        const dy = a.y - b.y;
        const d2 = dx * dx + dy * dy;
        if (d2 < LINK_DIST_SQ) {
          const alpha = (1 - d2 / LINK_DIST_SQ) * 0.55;
          ctx.strokeStyle = "rgba(" + LINE_RGB + "," + alpha.toFixed(3) + ")";
          ctx.lineWidth = 1;
          ctx.beginPath();
          ctx.moveTo(a.x, a.y);
          ctx.lineTo(b.x, b.y);
          ctx.stroke();
        }
      }
    }
    // --- линии от курсора к ближайшим ---
    if (mouse.active) {
      for (let i = 0; i < particles.length; i++) {
        const p = particles[i];
        const dx = p.x - mouse.x;
        const dy = p.y - mouse.y;
        const d2 = dx * dx + dy * dy;
        if (d2 < MOUSE_DIST_SQ) {
          const alpha = (1 - d2 / MOUSE_DIST_SQ) * 0.8;
          ctx.strokeStyle = "rgba(" + LINE_RGB + "," + alpha.toFixed(3) + ")";
          ctx.lineWidth = 1;
          ctx.beginPath();
          ctx.moveTo(mouse.x, mouse.y);
          ctx.lineTo(p.x, p.y);
          ctx.stroke();
        }
      }
    }
    // Следующий кадр только если вкладка активна. Guard rafId исключает
    // случай, когда visibilitychange запросил ещё один rAF параллельно текущему —
    // без guard со временем накапливалось N параллельных tick-циклов и
    // частицы летали с N-кратной скоростью.
    if (running) schedule();
  }
  // Таймер вместо requestAnimationFrame: некоторые браузеры временно
  // ограничивают rAF во время scroll. Фон должен продолжать двигаться.
  function schedule() {
    if (running && !loopTimer) {
      loopTimer = window.setTimeout(() => { loopTimer = 0; tick(); }, 33);
    }
  }

  document.addEventListener("visibilitychange", () => {
    running = !document.hidden;
    if (running) {
      // На wake принудительно пересоздаём canvas — гарантирует чистый старт
      // и правильный размер если окно/DPR менялись пока вкладка была suspended.
      resize();
    }
    if (!running && loopTimer) { clearTimeout(loopTimer); loopTimer = 0; }
    schedule();
  });
  window.addEventListener("resize", resize, { passive: true });
  window.addEventListener("mousemove", onMouse, { passive: true });
  window.addEventListener("mouseout", onLeave, { passive: true });
  window.addEventListener("touchmove", onMouse, { passive: true });
  window.addEventListener("touchend", onLeave, { passive: true });
  // Не останавливаем mesh во время scroll: canvas фиксирован относительно
  // viewport и должен продолжать жить, пока пользователь листает страницу.
  // Производительность контролируется ограничением FPS и числом частиц выше.
  resize();
  schedule();

  // Глобальная точка остановки (для реактивного prefers-reduced-motion)
  window._meshStop = function() {
    running = false;
    if (loopTimer) { clearTimeout(loopTimer); loopTimer = 0; }
  };
})();
