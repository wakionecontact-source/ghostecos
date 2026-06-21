// Общие хелперы шопа: сессия, рендер шапки, тосты, API-обёртка.
(function () {
  window.SHOP = window.SHOP || {};

  SHOP.prefix = (window.SHOP_PREFIX || "").replace(/\/$/, "");

  SHOP.url = function (path) {
    if (path.startsWith("http://") || path.startsWith("https://")) return path;
    if (!path.startsWith("/")) path = "/" + path;
    if (SHOP.prefix && !path.startsWith(SHOP.prefix + "/") && path !== SHOP.prefix) {
      return SHOP.prefix + path;
    }
    return path;
  };

  SHOP.api = async function (path, opts) {
    opts = opts || {};
    const init = {
      method: opts.method || "GET",
      credentials: "include",
      headers: { "Accept": "application/json" }
    };
    if (opts.body !== undefined) {
      init.headers["Content-Type"] = "application/json";
      init.body = typeof opts.body === "string" ? opts.body : JSON.stringify(opts.body);
    }
    const r = await fetch(SHOP.url(path), init);
    let data = null;
    try { data = await r.json(); } catch (_) {}
    if (!r.ok) {
      const err = new Error((data && (data.detail || data.error)) || ("HTTP " + r.status));
      err.status = r.status;
      err.data = data;
      throw err;
    }
    return data;
  };

  SHOP.toast = function (msg, kind) {
    let t = document.getElementById("__toast");
    if (!t) {
      t = document.createElement("div");
      t.id = "__toast";
      t.className = "toast";
      document.body.appendChild(t);
    }
    t.textContent = msg;
    t.className = "toast show" + (kind ? " " + kind : "");
    clearTimeout(SHOP._toastT);
    SHOP._toastT = setTimeout(() => { t.className = "toast"; }, 2400);
  };

  SHOP.escape = function (s) {
    return String(s || "").replace(/[&<>"']/g, c => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    }[c]));
  };

  SHOP.loadMe = async function () {
    try { return await SHOP.api("/api/me"); }
    catch (_) { return null; }
  };

  SHOP.renderNav = function (me) {
    const nav = document.querySelector("nav");
    if (!nav) return;
    const right = nav.querySelector(".nav-right");
    if (!right) return;
    right.innerHTML = "";

    if (!me) {
      const a = document.createElement("a");
      a.className = "nav-btn";
      a.href = SHOP.url("/login");
      a.innerHTML = '<i class="fa-solid fa-right-to-bracket"></i> Вход';
      right.appendChild(a);
      return;
    }

    // Иконка профиля
    const wrap = document.createElement("div");
    wrap.className = "profile-wrap";
    const btn = document.createElement("button");
    btn.className = "profile-btn";
    btn.title = me.gc_username;
    btn.textContent = (me.gc_username || "?").slice(0, 1).toUpperCase();
    wrap.appendChild(btn);

    const menu = document.createElement("div");
    menu.className = "profile-menu";
    menu.innerHTML = `
      <div class="pm-head">
        <b>${SHOP.escape(me.gc_username)}</b>
        ${me.has_premium ? '<span class="badge badge-green">Premium ✓</span>' : '<span class="badge badge-purple">Free</span>'}
      </div>
      <a href="${SHOP.url("/profile")}"><i class="fa-solid fa-user"></i>&nbsp; Мой профиль</a>
      <a href="${SHOP.url("/premium")}"><i class="fa-solid fa-crown"></i>&nbsp; ${me.has_premium ? 'Мой Premium' : 'Купить Premium'}</a>
      <div class="pm-sep"></div>
      <a href="/social"><i class="fa-solid fa-hashtag"></i>&nbsp; GhostSocial</a>
      <a href="/chat/?from=${encodeURIComponent(location.pathname)}"><i class="fa-solid fa-comments"></i>&nbsp; GhostChat</a>
      <div class="pm-sep"></div>
      <button id="__logout"><i class="fa-solid fa-right-from-bracket"></i>&nbsp; Выйти</button>
    `;
    wrap.appendChild(menu);
    right.appendChild(wrap);

    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      menu.classList.toggle("show");
    });
    document.addEventListener("click", () => menu.classList.remove("show"));
    menu.querySelector("#__logout").addEventListener("click", function () {
      SHOP.confirm({
        title: "Выйти из аккаунта?",
        msg: "Вы выйдете во всех вкладках GhostEcos — соцсеть, чат и магазин.",
        okText: "Выйти",
        danger: true,
        onOk: async function () {
          try { await SHOP.api("/api/logout", { method: "POST" }); } catch (_) {}
          localStorage.removeItem("gs_token");
          localStorage.removeItem("gs_me");
          document.cookie = "gs_token=; path=/; max-age=0; SameSite=Lax; Secure";
          location.href = SHOP.url("/login");
        }
      });
    });
  };

  // ── Confirm dialog (динамически создаётся в body при первом вызове) ───────────
  SHOP.confirm = function (opts) {
    opts = opts || {};
    var overlay = document.getElementById("__sc_overlay");
    if (!overlay) {
      var styleId = "__sc_style";
      if (!document.getElementById(styleId)) {
        var st = document.createElement("style"); st.id = styleId;
        st.textContent = ".__sc_overlay{position:fixed;inset:0;background:rgba(2,6,23,0.7);z-index:600;display:flex;align-items:center;justify-content:center;padding:24px;opacity:0;pointer-events:none;transition:opacity 0.2s;backdrop-filter:blur(6px);-webkit-backdrop-filter:blur(6px);font-family:inherit;}"
          + ".__sc_overlay.open{opacity:1;pointer-events:all;}"
          + ".__sc_box{width:100%;max-width:340px;background:rgba(9,14,30,0.98);border:1px solid rgba(255,255,255,0.13);border-radius:22px;padding:26px 22px 20px;text-align:center;color:#f1f5f9;transform:scale(0.92);transition:transform 0.25s cubic-bezier(0.32,0.72,0,1);box-shadow:0 20px 50px rgba(0,0,0,0.5);}"
          + ".__sc_overlay.open .__sc_box{transform:scale(1);}"
          + ".__sc_icon{width:56px;height:56px;border-radius:50%;display:flex;align-items:center;justify-content:center;margin:0 auto 16px;font-size:22px;background:rgba(244,63,94,0.12);color:#f43f5e;}"
          + ".__sc_t{font-size:18px;font-weight:700;margin-bottom:6px;}"
          + ".__sc_m{font-size:14px;color:#94a3b8;line-height:1.5;margin-bottom:22px;}"
          + ".__sc_actions{display:flex;gap:10px;}"
          + ".__sc_btn{flex:1;padding:13px;border-radius:13px;border:none;font-size:15px;font-weight:700;cursor:pointer;font-family:inherit;}"
          + ".__sc_btn.cancel{background:rgba(255,255,255,0.06);color:#f1f5f9;border:1px solid rgba(255,255,255,0.13);}"
          + ".__sc_btn.ok{background:linear-gradient(90deg,#f43f5e,#e11d48);color:#fff;}";
        document.head.appendChild(st);
      }
      overlay = document.createElement("div");
      overlay.id = "__sc_overlay";
      overlay.className = "__sc_overlay";
      overlay.innerHTML = '<div class="__sc_box"><div class="__sc_icon"><i class="fa-solid fa-right-from-bracket"></i></div><div class="__sc_t" id="__sc_title"></div><div class="__sc_m" id="__sc_msg"></div><div class="__sc_actions"><button class="__sc_btn cancel" id="__sc_cancel">Отмена</button><button class="__sc_btn ok" id="__sc_ok">Ок</button></div></div>';
      document.body.appendChild(overlay);
    }
    document.getElementById("__sc_title").textContent = opts.title || "Подтвердите";
    document.getElementById("__sc_msg").textContent = opts.msg || "";
    var okBtn = document.getElementById("__sc_ok");
    okBtn.textContent = opts.okText || "Ок";
    overlay.classList.add("open");
    var close = function () { overlay.classList.remove("open"); };
    okBtn.onclick = function () { close(); if (opts.onOk) opts.onOk(); };
    document.getElementById("__sc_cancel").onclick = close;
    overlay.onclick = function (e) { if (e.target === overlay) close(); };
  };

  // SSO sync: токен удалили в другой вкладке → отправляем на /login
  window.addEventListener("storage", function (e) {
    if (e.key === "gs_token" && !e.newValue) {
      location.href = SHOP.url("/login");
    }
  });
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) return;
    var hasCookie = document.cookie.split(";").some(function (c) { return c.trim().indexOf("gs_token=") === 0; });
    var hasLocal = !!localStorage.getItem("gs_token");
    if (hasLocal && !hasCookie) {
      localStorage.removeItem("gs_token");
      localStorage.removeItem("gs_me");
      location.reload();
    }
  });

  // Требуем авторизацию — редиректим на /login если нет сессии.
  SHOP.requireAuth = async function () {
    const me = await SHOP.loadMe();
    if (!me) {
      location.href = SHOP.url("/login") + "?next=" + encodeURIComponent(location.pathname);
      return null;
    }
    return me;
  };

  // Тихая авторизация — не редиректит если нет сессии.
  SHOP.tryAuth = async function () {
    return await SHOP.loadMe();
  };
})();
