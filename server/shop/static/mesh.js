// Mesh-сеть на canvas: точки с линиями, разбегаются от курсора.
// Вставляет <canvas id="mesh-bg"> в body и сам его рисует.
(function () {
  if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    return; // уважаем настройки пользователя
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
    // ~1 точка на 9000 px², ограничим разумными рамками
    const n = Math.round(area / 9000);
    return Math.max(35, Math.min(n, 110));
  }
  function resize() {
    W = window.innerWidth;
    H = window.innerHeight;
    DPR = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width  = Math.floor(W * DPR);
    canvas.height = Math.floor(H * DPR);
    canvas.style.width  = W + "px";
    canvas.style.height = H + "px";
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
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
  let rafId = 0; // guard от двойного rAF при visibilitychange
  function tick() {
    rafId = 0;
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
    if (running && !rafId) rafId = requestAnimationFrame(tick);
  }

  function schedule() {
    if (running && !rafId) rafId = requestAnimationFrame(tick);
  }

  document.addEventListener("visibilitychange", () => {
    running = !document.hidden;
    schedule();
  });
  window.addEventListener("resize", resize, { passive: true });
  window.addEventListener("mousemove", onMouse, { passive: true });
  window.addEventListener("mouseout", onLeave, { passive: true });
  window.addEventListener("touchmove", onMouse, { passive: true });
  window.addEventListener("touchend", onLeave, { passive: true });
  resize();
  schedule();
})();
