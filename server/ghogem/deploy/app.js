(() => {
  "use strict";

  const API = "/ghogem-api";
  const WS_URL = (() => {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    return `${proto}//${location.host}${API}/ws/chat`;
  })();

  const tg = window.Telegram && window.Telegram.WebApp;
  if (tg) {
    try {
      tg.ready();
      tg.expand();
      tg.setHeaderColor && tg.setHeaderColor("#0a0a0f");
      tg.setBackgroundColor && tg.setBackgroundColor("#0a0a0f");
    } catch (e) {}
  }

  const $ = (s) => document.querySelector(s);
  const $$ = (s) => Array.from(document.querySelectorAll(s));

  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function escAttr(s) { return esc(s).replace(/"/g, "&quot;"); }
  function extOf(name) { const m = /\.([a-z0-9]+)$/i.exec(name || ""); return m ? m[1].toLowerCase() : ""; }
  const PREVIEWABLE = new Set(["html", "htm", "svg"]);

  // ═══════════════ LOCAL STORAGE (гостевой режим — источник правды) ═══════════════
  const LS_CHATS = "ghogem:chats";       // [{id,title,createdAt}]
  const LS_MSGS_PREFIX = "ghogem:msgs:"; // ghogem:msgs:<chatId> -> [{role,text,ts}]
  const LS_PREFS = "ghogem:prefs";

  function lsGetChats() {
    try { return JSON.parse(localStorage.getItem(LS_CHATS) || "[]"); } catch (e) { return []; }
  }
  function lsSaveChats(list) {
    try { localStorage.setItem(LS_CHATS, JSON.stringify(list)); } catch (e) {}
  }
  function lsGetMsgs(chatId) {
    try { return JSON.parse(localStorage.getItem(LS_MSGS_PREFIX + chatId) || "[]"); } catch (e) { return []; }
  }
  function lsSaveMsgs(chatId, msgs) {
    try { localStorage.setItem(LS_MSGS_PREFIX + chatId, JSON.stringify(msgs.slice(-200))); } catch (e) {}
  }
  function lsAppendMsg(chatId, role, text, events) {
    const msgs = lsGetMsgs(chatId);
    const entry = { role, text, ts: Date.now() };
    if (events && events.length) entry.events = events;
    msgs.push(entry);
    lsSaveMsgs(chatId, msgs);
  }
  function lsDeleteChat(chatId) {
    try { localStorage.removeItem(LS_MSGS_PREFIX + chatId); } catch (e) {}
    lsSaveChats(lsGetChats().filter((c) => c.id !== chatId));
  }
  function lsGetPrefs() {
    try { return JSON.parse(localStorage.getItem(LS_PREFS) || "{}"); } catch (e) { return {}; }
  }
  function lsSavePrefs(p) {
    try { localStorage.setItem(LS_PREFS, JSON.stringify(p)); } catch (e) {}
  }

  function uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return "c" + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  }

  // ═══════════════ АККАУНТ GhostEcos (SSO) ═══════════════
  // gs_token — общий токен экосистемы (соцсеть, банк, нация). Держим его и в
  // localStorage, и в cookie на весь домен: cookie читает сервер (в том числе
  // при WS-хендшейке и по прямым ссылкам на файлы), а localStorage позволяет
  // подхватить вход, сделанный в другом приложении GhostEcos на этом домене.
  const LS_GS_TOKEN = "gs_token";
  const LS_IMPORT_DONE = "ghogem:imported";

  function cookieGet(name) {
    const m = new RegExp("(?:^|;\\s*)" + name + "=([^;]*)").exec(document.cookie);
    return m ? decodeURIComponent(m[1]) : "";
  }
  function ssoCookieSet(t) {
    const secure = location.protocol === "https:" ? "; Secure" : "";
    document.cookie = "gs_token=" + encodeURIComponent(t) + "; path=/; max-age=31536000; SameSite=Lax" + secure;
  }
  function ssoCookieClear() {
    const secure = location.protocol === "https:" ? "; Secure" : "";
    document.cookie = "gs_token=; path=/; max-age=0; SameSite=Lax" + secure;
  }
  function gsToken() {
    let ls = "";
    try { ls = localStorage.getItem(LS_GS_TOKEN) || ""; } catch (e) {}
    return ls || cookieGet("gs_token") || "";
  }
  function gsTokenSet(t) {
    try { localStorage.setItem(LS_GS_TOKEN, t); } catch (e) {}
    ssoCookieSet(t);
  }
  function gsTokenClear() {
    try { localStorage.removeItem(LS_GS_TOKEN); } catch (e) {}
    ssoCookieClear();
  }

  const acct = {
    ready: false, authed: false, kind: "guest", storage: "local",
    username: null, display: null,
    tg: null, tgLinked: false, linkConflict: false, canLinkWebapp: false,
    linkCode: null, botUsername: "", ssoUp: true, busy: false, notice: "",
  };
  function isServerStore() { return acct.storage === "server"; }

  // ═══════════════ STATE ═══════════════
  function modelPower(m) {
    const params = Number(m.params_b);
    if (Number.isFinite(params)) {
      if (params >= 100) return 100;
      if (params >= 30) return 70;
      if (params >= 12) return 50;
      return 20;
    }
    const explicitTier = String(m.power_tier || "").toLowerCase();
    if (explicitTier === "crown") return 100;
    if (explicitTier === "green") return 70;
    if (explicitTier === "yellow") return 50;
    if (explicitTier === "red") return 20;
    const s = ((m.id || "") + " " + (m.api_model || "") + " " + (m.name || "")).toLowerCase();
    let p = 10;
    if (/550b|ultra/.test(s)) p = 100;
    else if (/120b|405b|large/.test(s)) p = 85;
    else if (/70b|72b|super/.test(s)) p = 70;
    else if (/32b|31b|30b|27b|medium|v3\.1|v3/.test(s)) p = 55;
    else if (/14b|13b|12b|codestral/.test(s)) p = 40;
    else if (/9b|8b|7b|small|nemo|flash|mini/.test(s)) p = 25;
    else if (/3b|1\.5/.test(s)) p = 12;
    if (/omni|reasoning/.test(s)) p += 5;
    return p;
  }

  function modelTier(m) {
    let key = String(m.power_tier || "").toLowerCase();
    if (!/^(red|yellow|green|crown)$/.test(key)) {
      const params = Number(m.params_b);
      if (Number.isFinite(params)) key = params >= 100 ? "crown" : params >= 30 ? "green" : params >= 12 ? "yellow" : "red";
      else key = (m.power || 0) >= 100 ? "crown" : (m.power || 0) >= 70 ? "green" : (m.power || 0) >= 50 ? "yellow" : "red";
    }
    const labels = { red: "RED", yellow: "YELLOW", green: "GREEN", crown: "CROWN" };
    return { key, label: labels[key], title: `${labels[key]} · уровень по размеру/мощности модели` };
  }

  function modelParamsText(m) {
    const total = Number(m.params_b);
    if (Number.isFinite(total)) {
      const fmt = (value) => Number.isInteger(value) ? String(value) : value.toFixed(1).replace(/\.0$/, "");
      const totalText = `${fmt(total)}B`;
      const active = Number(m.active_params_b);
      return Number.isFinite(active) ? `${totalText} total · ${fmt(active)}B active` : totalText;
    }
    return m.params_label || "размер не раскрыт";
  }

  const prefs = Object.assign({ mesh: true, enterSend: true, density: "comfortable" }, lsGetPrefs());

  const state = {
    model: "",
    models: [],
    ranking: [],
    rankingFilter: "all",
    providers: {},
    activeProv: "",
    limited: {},
    webSearch: false,
    forceTts: false,
    pageReady: false,
    previewOrigin: null,
    sending: false,
    initData: (tg && tg.initData) || "",
    chatId: null,
    context: "",
    contexts: [],
    serverChats: [],
    serverCurrent: null,
    ws: null,
    wsReady: false,
    wsQueue: [],
    liveMsg: null,
    pendingActions: null,
    canvasFiles: [],
    activeCanvasFile: null,
    canvasMode: "code",
  };

  // ═══════════════ MESH BACKGROUND ═══════════════
  // /mesh.js (общий для GE-сайтов) сам создаёт <canvas id="mesh-bg"> и
  // рисует в него — здесь только включаем/выключаем по настройке.
  function setMeshEnabled(on) {
    const canvas = document.getElementById("mesh-bg");
    if (canvas) canvas.style.display = on ? "" : "none";
  }

  // ═══════════════ API (REST helpers) ═══════════════
  async function api(path, opts) {
    opts = opts || {};
    const headers = Object.assign({ "Content-Type": "application/json" }, opts.headers || {});
    if (state.initData) headers["X-Tg-Init-Data"] = state.initData;
    // Cookie летит и сама, но в Telegram WebApp (iframe) SameSite=Lax её режет —
    // поэтому токен всегда дублируем заголовком.
    const t = gsToken();
    if (t) headers["X-Gs-Token"] = t;
    const res = await fetch(API + path, Object.assign({}, opts, { headers }));
    const ct = res.headers.get("content-type") || "";
    let data = null;
    if (ct.includes("application/json")) { try { data = await res.json(); } catch (e) {} }
    else { data = await res.text(); }
    if (!res.ok) {
      let msg = (data && (data.detail || data.error || data.message)) || (typeof data === "string" ? data.slice(0, 180) : res.statusText);
      if (typeof msg === "string" && msg.length > 140) msg = msg.slice(0, 140) + "…";
      const err = new Error(msg || "error " + res.status);
      err.status = res.status;
      throw err;
    }
    return data;
  }

  // ═══════════════ USER ═══════════════
  function plural(n, one, few, many) {
    const a = Math.abs(n) % 100, b = a % 10;
    if (a > 10 && a < 20) return many;
    if (b > 1 && b < 5) return few;
    if (b === 1) return one;
    return many;
  }

  function renderUserChip() {
    const tgU = tg && tg.initDataUnsafe && tg.initDataUnsafe.user;
    let name = "Гость", sub = "войти через GhostEcos", av = "G", authed = false;
    if (acct.authed) {
      name = acct.display || acct.username || "Аккаунт";
      sub = "@" + (acct.username || "");
      av = (name.trim() || "A")[0].toUpperCase();
      authed = true;
    } else if (acct.kind === "tg") {
      const u = acct.tg || {};
      name = u.name || (tgU && (tgU.first_name || tgU.username)) || "Telegram";
      sub = u.username ? "@" + u.username : "вход через Telegram";
      av = (name || "U")[0].toUpperCase();
      authed = true;
    } else if (tgU) {
      name = tgU.first_name || tgU.username || "User";
      sub = tgU.username ? "@" + tgU.username : "id " + tgU.id;
      av = (name || "U")[0].toUpperCase();
    }
    const nameEl = $("#userName"), subEl = $("#userSub"), avEl = $("#userAv"), chip = $("#userChip");
    if (nameEl) nameEl.textContent = name;
    if (subEl) subEl.textContent = sub;
    if (avEl) avEl.textContent = av;
    if (chip) chip.classList.toggle("authed", authed);
    const hint = $("#settingsAcctHint");
    if (hint) {
      hint.textContent = acct.authed
        ? "Вошёл как @" + (acct.username || "") + " — чаты на сервере"
        : acct.kind === "tg"
          ? "Вход через Telegram — чаты на сервере"
          : "Без входа — чаты только на этом устройстве";
    }
  }

  // Кто мы для сервера. Токен мог поставить любой сайт экосистемы, поэтому
  // источник правды — ответ /auth/me, а не наличие токена в localStorage.
  async function authRefresh() {
    try {
      const d = await api("/auth/me");
      acct.authed = !!d.authed;
      acct.kind = d.kind || "guest";
      acct.storage = d.storage || "local";
      acct.username = d.username || null;
      acct.display = d.display_name || null;
      acct.tg = d.tg || null;
      acct.tgLinked = !!d.tg_linked;
      acct.linkConflict = !!d.link_conflict;
      acct.canLinkWebapp = !!d.can_link_webapp;
      acct.linkCode = d.link_code || null;
      acct.botUsername = d.bot_username || "";
      acct.ssoUp = d.sso !== false;
      // Токен есть, но владельца сервер не нашёл — сессия истекла или её
      // отозвали. Держать такой токен нельзя: он поедет в каждый запрос.
      if (d.token_invalid) gsTokenClear();
    } catch (e) {
      console.warn("[auth/me]", e);
      acct.notice = "Сервер аккаунтов не ответил: " + e.message;
    }
    acct.ready = true;
    renderUserChip();
    renderAccount();
    return acct;
  }

  async function loadServerChats() {
    if (!isServerStore()) { state.serverChats = []; state.serverCurrent = null; return; }
    try {
      const d = await api("/chats");
      const items = (d.chats || []).filter((c) => c && c.id);
      // chat_id — это ms-таймстамп создания, так что сортировка по нему даёт
      // тот же порядок «новые сверху», что и у гостевых чатов.
      items.sort((a, b) => (parseInt(b.id, 10) || 0) - (parseInt(a.id, 10) || 0));
      state.serverChats = items;
      state.serverCurrent = d.current || null;
    } catch (e) {
      console.warn("[chats]", e);
      state.serverChats = [];
      state.serverCurrent = null;
    }
  }

  // Пароль проверяет соцсеть — тот же эндпоинт, что у /social и /nation.
  async function doLogin(username, password) {
    const r = await fetch("/api/soc/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username: String(username || "").trim().toLowerCase(), password: password || "" }),
    });
    const d = await r.json().catch(() => ({}));
    if (!r.ok || !d.token) throw new Error(d.detail || "Неверный логин или пароль");
    gsTokenSet(d.token);
    return d;
  }

  // Владелец соединения/чатов сменился — перечитываем всё, что от него зависит.
  async function afterAuthChange() {
    await loadServerChats();
    state.chatId = null;
    await ensureActiveChat();
    renderChatList();
    try { await renderMessages(); } catch (e) { console.error(e); }
    loadFiles();
    // Токен сервер читает один раз, при WS-хендшейке: без переподключения
    // сокет остался бы от прежнего владельца.
    reconnectWS();
    loadModels();
  }

  // Гостевые чаты лежат в localStorage. Не перенести их — значит после входа
  // показать пустой список, как будто переписка потерялась.
  async function maybeImportLocalChats() {
    const who = acct.username || "?";
    let done = "";
    try { done = localStorage.getItem(LS_IMPORT_DONE) || ""; } catch (e) {}
    if (done === who) return;
    const markDone = () => { try { localStorage.setItem(LS_IMPORT_DONE, who); } catch (e) {} };
    const local = lsGetChats();
    const payload = [];
    local.forEach((c) => {
      const msgs = lsGetMsgs(c.id)
        .filter((m) => (m.role === "user" || m.role === "assistant") && String(m.text || "").trim())
        .map((m) => ({ role: m.role, text: String(m.text || "") }));
      if (msgs.length) payload.push({ created_at: c.createdAt || null, messages: msgs });
    });
    if (!payload.length) { markDone(); return; }
    const n = payload.length;
    const ok = confirm(
      "Перенести " + n + " " + plural(n, "гостевой чат", "гостевых чата", "гостевых чатов") +
      " в аккаунт @" + who + "?\n\nОтмена — оставить их только в этом браузере."
    );
    if (!ok) { markDone(); return; }
    try {
      const d = await api("/chats/import", { method: "POST", body: JSON.stringify({ chats: payload.slice(0, 50) }) });
      markDone();
      // Локальные копии убираем — иначе после выхода та же переписка покажется
      // ещё раз, уже как гостевая.
      local.forEach((c) => { try { localStorage.removeItem(LS_MSGS_PREFIX + c.id); } catch (e) {} });
      lsSaveChats([]);
      acct.notice = "Перенесено чатов: " + (d.imported || 0) +
        (d.skipped ? ", пропущено пустых: " + d.skipped : "");
    } catch (e) {
      acct.notice = "Перенос не удался: " + e.message;
    }
  }

  async function handleLogin() {
    const u = ($("#acctUser") || {}).value || "";
    const p = ($("#acctPass") || {}).value || "";
    if (!u.trim() || !p) { acct.notice = "Введи логин и пароль"; renderAccount(); return; }
    acct.busy = true; acct.notice = ""; renderAccount();
    try {
      await doLogin(u, p);
      await authRefresh();
      if (acct.authed) {
        await maybeImportLocalChats();
        await afterAuthChange();
        if (!acct.notice) acct.notice = "Вошёл как @" + (acct.username || "");
      } else {
        acct.notice = "Токен получен, но сервер его не признал — попробуй ещё раз";
      }
    } catch (e) {
      gsTokenClear();
      acct.notice = e.message || "Не удалось войти";
    } finally {
      acct.busy = false;
      renderUserChip();
      renderAccount();
    }
  }

  async function handleLogout() {
    if (!confirm("Выйти из аккаунта?\n\nТокен общий для GhostEcos — выйдешь из соцсети и банка на этом устройстве тоже.")) return;
    gsTokenClear();
    acct.notice = "";
    await authRefresh();
    await afterAuthChange();
    acct.notice = "Вышел из аккаунта";
    renderUserChip();
    renderAccount();
  }

  async function handleLinkWebapp() {
    acct.busy = true; acct.notice = ""; renderAccount();
    try {
      const d = await api("/auth/link/webapp", { method: "POST" });
      acct.notice = (d.message || "Telegram привязан") +
        (d.chats_moved ? " · перенесено чатов: " + d.chats_moved : "");
      await authRefresh();
      await afterAuthChange();
    } catch (e) {
      acct.notice = e.message;
    } finally {
      acct.busy = false;
      renderUserChip();
      renderAccount();
    }
  }

  async function handleLinkCode() {
    acct.busy = true; acct.notice = ""; renderAccount();
    try {
      const d = await api("/auth/link/code", { method: "POST" });
      acct.linkCode = { code: d.code, expires_in: d.expires_in };
      if (d.bot_username) acct.botUsername = d.bot_username;
    } catch (e) {
      acct.notice = e.message;
    } finally {
      acct.busy = false;
      renderAccount();
    }
  }

  async function handleUnlink() {
    if (!confirm("Отвязать Telegram?\n\nЧаты останутся в Telegram-аккаунте — на сайте ты их больше не увидишь.")) return;
    acct.busy = true; acct.notice = ""; renderAccount();
    try {
      const d = await api("/auth/unlink", { method: "POST" });
      acct.notice = d.message || "Telegram отвязан";
      await authRefresh();
      await afterAuthChange();
    } catch (e) {
      acct.notice = e.message;
    } finally {
      acct.busy = false;
      renderUserChip();
      renderAccount();
    }
  }

  function renderAccount() {
    const box = $("#accountBox");
    if (!box) return;
    const parts = [];
    if (acct.notice) parts.push('<div class="acct-note">' + esc(acct.notice) + "</div>");

    if (!acct.ssoUp) {
      parts.push('<div class="empty">Вход недоступен — сервис аккаунтов сейчас не отвечает. Чаты пока сохраняются локально.</div>');
      box.innerHTML = parts.join("");
      return;
    }

    if (!acct.authed) {
      const hint = acct.kind === "tg"
        ? "Ты открыл сайт из Telegram, поэтому чаты уже уходят в твой Telegram-аккаунт. Вход в GhostEcos свяжет их с общим аккаунтом экосистемы."
        : "Без входа чаты и файлы живут только в этом браузере.";
      const returnTo = encodeURIComponent(location.pathname + location.search + location.hash);
      parts.push(
        '<div class="settings-group solid-panel acct-form">' +
          '<p class="settings-hint">' + esc(hint) + "</p>" +
          '<div class="acct-actions">' +
            '<a class="chip matte-button acct-primary" href="/login?return=' + returnTo + '">Войти</a>' +
            '<a class="chip matte-button" href="/register?return=' + returnTo + '">Регистрация</a>' +
          "</div>" +
          '<p class="settings-hint">Один аккаунт на соцсеть, банк, нацию и GhoGem.</p>' +
        "</div>"
      );
      box.innerHTML = parts.join("");
      bindAccountEvents();
      return;
    }

    parts.push(
      '<div class="settings-group solid-panel">' +
        '<div class="settings-row"><div>' +
          '<div class="settings-label">' + esc(acct.display || acct.username || "Аккаунт") + "</div>" +
          '<div class="settings-hint">@' + esc(acct.username || "") + " · чаты и файлы на сервере, видны с любого устройства</div>" +
        "</div>" +
        '<button type="button" class="chip danger" id="btnAcctLogout">Выйти</button>' +
        "</div>" +
      "</div>"
    );

    const rows = [];
    if (acct.tgLinked) {
      const t = acct.tg || {};
      const who = t.username ? "@" + t.username : (t.name || (t.id ? "id " + t.id : "аккаунт бота"));
      rows.push(
        '<div class="settings-row"><div>' +
          '<div class="settings-label">Telegram привязан</div>' +
          '<div class="settings-hint">' + esc(who) + " · чаты бота и сайта общие</div>" +
        "</div>" +
        '<button type="button" class="chip danger" id="btnAcctUnlink"' + (acct.busy ? " disabled" : "") + ">Отвязать</button>" +
        "</div>"
      );
    } else if (acct.linkConflict) {
      rows.push(
        '<div class="settings-row"><div>' +
          '<div class="settings-label">Этот Telegram уже занят</div>' +
          '<div class="settings-hint">Он привязан к другому аккаунту GhostEcos. Отвяжи там — командой /unlink в боте.</div>' +
        "</div></div>"
      );
    } else {
      if (acct.canLinkWebapp) {
        rows.push(
          '<div class="settings-row"><div>' +
            '<div class="settings-label">Привязать этот Telegram</div>' +
            '<div class="settings-hint">Чаты, файлы и подписка станут общими с ботом</div>' +
          "</div>" +
          '<button type="button" class="chip matte-button" id="btnAcctLinkWebapp"' + (acct.busy ? " disabled" : "") + ">Привязать</button>" +
          "</div>"
        );
      }
      const code = acct.linkCode && acct.linkCode.code;
      const bot = acct.botUsername;
      rows.push(
        '<div class="settings-row"><div>' +
          '<div class="settings-label">Привязка по коду</div>' +
          '<div class="settings-hint">' +
            (code
              ? 'Отправь боту <code class="acct-cmd">/link ' + esc(code) + "</code>"
              : "Из браузера: получи код и пришли его боту") +
          "</div>" +
          (code && bot
            ? '<a class="acct-link" href="https://t.me/' + escAttr(bot) + "?start=link" + escAttr(code) +
              '" target="_blank" rel="noopener">Открыть бота →</a>'
            : "") +
        "</div>" +
        (code
          ? '<button type="button" class="acct-code" id="btnAcctCopyCode" title="Скопировать">' + esc(code) + "</button>"
          : '<button type="button" class="chip matte-button" id="btnAcctLinkCode"' + (acct.busy ? " disabled" : "") + ">Получить код</button>") +
        "</div>"
      );
    }
    parts.push('<div class="settings-group solid-panel">' + rows.join("") + "</div>");
    box.innerHTML = parts.join("");
    bindAccountEvents();
  }

  function bindAccountEvents() {
    const on = (id, fn, ev) => {
      const el = $(id);
      if (el) el.addEventListener(ev || "click", fn);
    };
    on("#btnAcctLogin", handleLogin);
    on("#btnAcctLogout", handleLogout);
    on("#btnAcctLinkWebapp", handleLinkWebapp);
    on("#btnAcctLinkCode", handleLinkCode);
    on("#btnAcctUnlink", handleUnlink);
    const pass = $("#acctPass");
    if (pass) pass.addEventListener("keydown", (e) => { if (e.key === "Enter") handleLogin(); });
    const user = $("#acctUser");
    if (user) user.addEventListener("keydown", (e) => { if (e.key === "Enter") { const p = $("#acctPass"); if (p) p.focus(); } });
    const copy = $("#btnAcctCopyCode");
    if (copy) {
      copy.addEventListener("click", () => {
        const code = (acct.linkCode && acct.linkCode.code) || "";
        const said = () => { copy.classList.add("copied"); copy.textContent = "Скопировано"; };
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText("/link " + code).then(said).catch(() => {});
        }
      });
    }
  }

  function openAccount() {
    showView("account");
    renderAccount();
    // Статус мог измениться в другой вкладке/приложении экосистемы.
    authRefresh();
  }

  // ═══════════════ VIEW NAVIGATION ═══════════════
  function showView(name) {
    $$(".view").forEach((v) => v.classList.toggle("active", v.id === "view-" + name));
    $("#workspace").classList.toggle("active", name === "chat");
    closeSb();
  }

  async function loadContexts() {
    const tree = $("#contextTree");
    if (!tree) return;
    try {
      const data = await api("/contexts");
      state.contexts = data.contexts || [];
      if (!state.contexts.length) { tree.innerHTML = '<div class="empty">Контекстов пока нет</div>'; return; }
      tree.innerHTML = state.contexts.map((ctx) => `
        <div class="ctx-product" data-context="${escAttr(ctx.id)}">
          <button type="button" class="ctx-product-row"><svg class="ic sm" viewBox="0 0 24 24"><path d="M5 4.5A2.5 2.5 0 017.5 2H20v17.5A2.5 2.5 0 0017.5 17H5z"/><path d="M5 4.5v15A2.5 2.5 0 007.5 22H20"/></svg><span>${esc(ctx.name)}</span><span class="ctx-chevron">›</span></button>
          <div class="ctx-chats">${(ctx.chats || []).map((chat) => `<button type="button" class="ctx-chat-row" data-context-id="${escAttr(ctx.id)}" data-chat-id="${escAttr(chat.id)}"><span class="ctx-file-dot">·</span><span>${esc(chat.title || "Новый чат")}</span><span class="ctx-count">${chat.messages || 0}</span></button>`).join("") || '<div class="ctx-empty">Чатов пока нет</div>'}</div>
        </div>`).join("");
      tree.querySelectorAll(".ctx-product-row").forEach((button) => button.addEventListener("click", () => button.parentElement.classList.toggle("open")));
      tree.querySelectorAll(".ctx-chat-row").forEach((button) => button.addEventListener("click", () => openContextChat(button.dataset.contextId, button.dataset.chatId)));
    } catch (e) { tree.innerHTML = '<div class="empty">Не удалось загрузить контексты</div>'; console.warn("[contexts]", e); }
  }

  async function openContextChat(contextId, chatId) {
    if (contextId !== "ghosou") return;
    try {
      const data = await api("/api/ghosou/chats/" + encodeURIComponent(chatId));
      state.context = contextId;
      state.chatId = data.conversation_id || chatId;
      showView("chat");
      $("#msgs").innerHTML = "";
      (data.messages || []).forEach((m) => addMsg(m.role, m.content, false, false));
      if (!(data.messages || []).length) renderSugs();
    } catch (e) { console.warn("[context chat]", e); }
  }
  function openSb() {
    const sb = $("#sidebar"), bd = $("#backdrop");
    if (sb) {
      sb.classList.add("open");
      sb.setAttribute("data-open", "1");
    }
    if (bd) bd.classList.add("show");
    document.body.classList.add("sb-open");
  }
  function closeSb() {
    const sb = $("#sidebar"), bd = $("#backdrop");
    if (sb) {
      sb.classList.remove("open");
      sb.removeAttribute("data-open");
    }
    if (bd) bd.classList.remove("show");
    document.body.classList.remove("sb-open");
  }
  function toggleSb() {
    const sb = $("#sidebar");
    if (sb && sb.classList.contains("open")) closeSb();
    else openSb();
  }
  function saveSelectedModel(key) {
    if (!key) return;
    state.model = key;
    prefs.lastModel = key;
    savePrefs();
    const label = $("#modelLabel");
    if (label) label.textContent = key.split(":").pop() || key;
    try {
      $$("#modelList .mcard").forEach((el) => {
        el.classList.toggle("on", el.getAttribute("data-id") === key);
      });
    } catch (_) {}
  }

  // ═══════════════ MODELS ═══════════════
  function isLimited(prov) {
    const until = state.limited[prov];
    if (!until) return false;
    if (Date.now() > until) { delete state.limited[prov]; return false; }
    return true;
  }
  function markLimited(prov, minutes) {
    if (!prov) return;
    state.limited[prov] = Date.now() + (minutes || 30) * 60 * 1000;
    renderProvTabs(); renderModels();
  }

  function normalizeModels(data) {
    const list = [];
    Object.keys(data.providers || {}).forEach((prov) => {
      (data.providers[prov] || []).forEach((m) => {
        list.push({
          id: m.key, name: m.name || (m.key || "").split(":").pop(), provider: prov,
          api_model: m.model || "", premium: !!m.premium, power: 0,
          creator: m.creator || "", params_b: m.params_b, active_params_b: m.active_params_b,
          params_label: m.params_label || "", power_tier: m.power_tier || "",
        });
      });
    });
    list.forEach((m) => { m.power = modelPower(m); });
    list.sort((a, b) => b.power - a.power || a.name.localeCompare(b.name));
    return list;
  }

  async function loadModels() {
    try {
      const data = await api("/models?init_data=" + encodeURIComponent(state.initData));
      state.models = normalizeModels(data);
      state.providers = {};
      state.models.forEach((m) => {
        (state.providers[m.provider] = state.providers[m.provider] || []).push(m);
      });
      if (!state.model) {
        // приоритет: последний выбор пользователя (если он ещё существует
        // среди доступных моделей) > дефолт с сервера > первая в списке
        const saved = prefs.lastModel;
        const savedStillExists = saved && state.models.some((m) => m.id === saved);
        state.model = (savedStillExists ? saved : null) || data.default || (state.models[0] && state.models[0].id) || "";
      }
      const cur = state.models.find((m) => m.id === state.model);
      state.activeProv = cur ? cur.provider : Object.keys(state.providers)[0] || "";
      const currentModel = state.models.find((m) => m.id === state.model);
      $("#modelLabel").textContent = (currentModel && currentModel.name) || (state.model || "").split(":").pop() || "модель";
      renderProvTabs(); renderModels();
    } catch (e) {
      $("#modelList").innerHTML = '<div class="empty">Не удалось загрузить модели: ' + esc(e.message) + "</div>";
    }
  }

  async function loadRanking() {
    const box = $("#rankingList");
    if (!box) return;
    box.innerHTML = '<div class="empty">Загружаю рейтинг…</div>';
    try {
      const data = await api("/ratings/ranking");
      state.ranking = Array.isArray(data.models) ? data.models : [];
      $("#rankingModelCount").textContent = Number(data.models_count || 0).toLocaleString("ru-RU");
      $("#rankingVoteCount").textContent = Number(data.votes_count || 0).toLocaleString("ru-RU");
      renderRanking();
    } catch (e) {
      box.innerHTML = '<div class="empty">Не удалось загрузить рейтинг: ' + esc(e.message) + "</div>";
    }
  }

  function renderRanking() {
    const box = $("#rankingList");
    if (!box) return;
    const filter = state.rankingFilter;
    const list = state.ranking.filter((item) => {
      if (filter === "free") return !item.premium;
      if (filter === "premium") return !!item.premium;
      if (filter === "multimodal") return !!item.multimodal;
      return true;
    });
    if (!list.length) {
      box.innerHTML = state.ranking.length
        ? '<div class="empty">По этому фильтру пока нет оценённых моделей</div>'
        : '<div class="empty">Пока нет сохранённых оценок моделей</div>';
      return;
    }
    box.innerHTML = list.map((item) => {
      const rating = item.rating || {};
      const votes = Math.max(0, Number(rating.votes) || 0);
      const average = Number(rating.average);
      const averageText = Number.isFinite(average) ? average.toFixed(2).replace(".", ",") : "—";
      const distribution = Array.isArray(rating.distribution) ? rating.distribution : [];
      const bars = [1, 2, 3, 4, 5].map((score, index) => {
        const count = Math.max(0, Number(distribution[index]) || 0);
        const width = votes ? Math.max(0, Math.min(100, count / votes * 100)) : 0;
        return `<div class="rating-dist-item" title="${score}/5: ${count}"><span>${score}</span><div><i style="width:${width}%"></i></div><small>${count}</small></div>`;
      }).join("");
      const tags = [
        item.premium ? '<span class="badge pro">PREMIUM</span>' : '<span class="badge rating-free">FREE</span>',
        item.multimodal ? '<span class="badge rating-multi">Мультимодальная</span>' : "",
      ].join("");
      const params = item.params_b != null
        ? `${Number(item.params_b).toLocaleString("ru-RU")}B${item.active_params_b != null ? ` · ${Number(item.active_params_b).toLocaleString("ru-RU")}B active` : ""}`
        : (item.params_label || "");
      const meta = [item.creator, item.provider, params].filter(Boolean).map(esc).join(" · ");
      const statusCode = String(item.status_code || "historical").replace(/[^a-z0-9_-]/gi, "");
      const isTopRank = Number(item.rank) === 1;
      return `<article class="ranking-card">
        <div class="ranking-place${isTopRank ? " top" : ""}">${Number(item.rank) || "—"}</div>
        <div class="ranking-model">
          <div class="ranking-title-row"><h3>${esc(item.name || item.key || "Модель")}</h3><div class="ranking-tags">${tags}</div></div>
          <div class="ranking-meta">${meta || esc(item.key || "")}</div>
          <div class="ranking-status ${statusCode}">${esc(item.status_label || "Статус неизвестен")}</div>
          <div class="rating-dist" role="img" aria-label="Распределение оценок от 1 до 5">${bars}</div>
        </div>
        <div class="ranking-score"><strong>${averageText}</strong><span>/ 5</span><small>${votes.toLocaleString("ru-RU")} ${plural(votes, "оценка", "оценки", "оценок")}</small></div>
      </article>`;
    }).join("");
  }

  function renderRatingFilters() {
    const box = $("#ratingFilters");
    if (!box) return;
    box.querySelectorAll("[data-rating-filter]").forEach((button) => {
      const active = button.getAttribute("data-rating-filter") === state.rankingFilter;
      button.classList.toggle("on", active);
      button.setAttribute("aria-pressed", active ? "true" : "false");
    });
  }

  function renderProvTabs() {
    const box = $("#provTabs");
    if (!box) return;
    const keys = Object.keys(state.providers).sort((a, b) => {
      const pa = Math.max(0, ...(state.providers[a] || []).map((m) => m.power || 0));
      const pb = Math.max(0, ...(state.providers[b] || []).map((m) => m.power || 0));
      return pb - pa || a.localeCompare(b);
    });
    box.innerHTML = keys.map((p) => {
      const lim = isLimited(p);
      const cls = "prov-tab" + (p === state.activeProv ? " on" : "") + (lim ? " limited" : "");
      const title = p.charAt(0).toUpperCase() + p.slice(1);
      return `<button type="button" class="${cls}" data-prov="${escAttr(p)}"${lim ? ' title="Лимит провайдера"' : ""}>${esc(title)}${lim ? " · лимит" : ""}</button>`;
    }).join("");
    box.querySelectorAll(".prov-tab").forEach((btn) => {
      btn.addEventListener("click", () => {
        state.activeProv = btn.getAttribute("data-prov");
        renderProvTabs(); renderModels();
      });
    });
  }

  function renderModels() {
    const box = $("#modelList");
    if (!box) return;
    const list = (state.providers[state.activeProv] || []).slice().sort((a, b) => b.power - a.power);
    const provLimited = isLimited(state.activeProv);
    if (!list.length) { box.innerHTML = '<div class="empty">Нет моделей</div>'; return; }
    box.innerHTML = list.map((m) => {
      const on = m.id === state.model ? " on" : "";
      const locked = provLimited ? " locked" : "";
      const badge = m.premium ? '<span class="badge pro">PRO</span>' : "";
      const tier = modelTier(m);
      const pwr = `<span class="badge tier ${tier.key}" title="${escAttr(tier.title)}">${tier.label}</span>`;
      const params = modelParamsText(m);
      const creator = m.creator ? ` · ${m.creator}` : "";
      const desc = provLimited
        ? "Лимит провайдера — попробуй позже или выбери другую модель"
        : m.premium
          ? "Premium: выше скорость, приоритет в очереди, без дневных ограничений"
          : (m.api_model || m.provider);
      return `<button type="button" class="mcard tier-${tier.key}${on}${locked}" data-id="${escAttr(m.id)}">
        <div><div class="nm">${esc(m.name)}${badge}${pwr}</div>
        <div class="ds">${esc(desc)}</div>
        <div class="model-meta">${esc(params)}${esc(creator)}</div></div>
      </button>`;
    }).join("");
    box.querySelectorAll(".mcard").forEach((btn) => {
      btn.addEventListener("click", () => {
        if (isLimited(state.activeProv)) return;
        saveSelectedModel(btn.getAttribute("data-id"));
        renderModels(); showView("chat");
      });
    });
  }

  // ═══════════════ CHATS (localStorage) ═══════════════
  function ensureChat() {
    let chats = lsGetChats();
    if (!state.chatId || !chats.find((c) => c.id === state.chatId)) {
      if (chats.length) {
        state.chatId = chats[0].id;
      } else {
        const id = uuid();
        chats = [{ id, title: "Новый чат", createdAt: Date.now() }];
        lsSaveChats(chats);
        state.chatId = id;
      }
    }
  }

  async function ensureActiveChat() {
    if (!isServerStore()) {
      ensureChat();
      return state.chatId;
    }
    const known = state.serverChats.find((c) => c.id === state.chatId);
    if (known) return state.chatId;
    const preferred = state.serverChats.find((c) => c.id === state.serverCurrent) || state.serverChats[0];
    if (preferred) {
      state.chatId = preferred.id;
      return state.chatId;
    }
    const created = await api("/chats/new", { method: "POST" });
    state.chatId = created.chat_id;
    state.serverCurrent = created.chat_id;
    state.serverChats = [{ id: created.chat_id, title: "Новый чат" }];
    return state.chatId;
  }

  function renderChatList() {
    const chats = isServerStore()
      ? state.serverChats
      : lsGetChats().slice().sort((a, b) => b.createdAt - a.createdAt);
    const list = $("#chatList");
    if (!chats.length) { list.innerHTML = '<div class="chat-row">Пока пусто</div>'; return; }
    list.innerHTML = chats.map((c) => {
      const on = c.id === state.chatId ? " on" : "";
      return `<div class="chat-row${on}" data-id="${escAttr(c.id)}">${esc(c.title || "Чат")}</div>`;
    }).join("");
    list.querySelectorAll(".chat-row").forEach((el) => {
      el.addEventListener("click", () => {
        const id = el.getAttribute("data-id");
        try {
          switchChat(id).catch((e) => console.error("switchChat failed", e));
        } finally {
          closeSb(); // страховка: закрыть сайдбар в любом случае, даже если switchChat упал
        }
      });
    });
  }

  async function switchChat(id) {
    // сайдбар закрываем сразу, до любой другой логики — если что-то ниже
    // упадёт с ошибкой, меню всё равно не останется висеть на экране
    showView("chat");
    state.context = "";
    state.chatId = id;
    state.canvasFiles = [];
    state.activeCanvasFile = null;
    setCanvasOpen(false);
    try {
      if (isServerStore()) await api("/chats/switch?chat_id=" + encodeURIComponent(id), { method: "POST" });
      await renderMessages();
      renderChatList();
      loadFiles();
    } catch (e) {
      console.error("switchChat render failed", e);
    }
  }

  function renderMessagesFromLocal() {
    const msgs = lsGetMsgs(state.chatId);
    $("#msgs").innerHTML = "";
    if (!msgs.length) {
      $("#msgs").innerHTML = '<div class="hero" id="hero"><div class="hero-mark"><img src="ghogemava.jpg" alt="GhoGem"/></div><h1>GhoGem</h1><p>Поиск · код · файлы · HTML — как в боте</p><div class="sugs" id="sugs"></div></div>';
      renderSugs();
      return;
    }
    msgs.forEach((m) => {
      if (m.role === "assistant" && m.events && m.events.length) {
        renderStoredAssistantMsg(m.events, m.text);
      } else {
        addMsg(m.role, m.text, false, false);
      }
    });
  }

  async function renderMessages() {
    if (!isServerStore()) {
      renderMessagesFromLocal();
      return;
    }
    const box = $("#msgs");
    box.innerHTML = "";
    if (!state.chatId) return;
    const data = await api("/chats/history?chat_id=" + encodeURIComponent(state.chatId));
    const msgs = data.messages || [];
    if (!msgs.length) {
      box.innerHTML = '<div class="hero" id="hero"><div class="hero-mark"><img src="ghogemava.jpg" alt="GhoGem"/></div><h1>GhoGem</h1><p>Поиск · код · файлы · HTML — как в боте</p><div class="sugs" id="sugs"></div></div>';
      renderSugs();
      return;
    }
    msgs.forEach((m) => addMsg(m.role, m.text, false, false));
  }

  // Восстанавливает сообщение ассистента из сохранённого журнала событий
  // (та же разметка, что и у живого стрима в createLiveAssistantMsg, но
  // рисуется сразу целиком, без спиннеров/анимации — сообщение уже завершено).
  function renderStoredAssistantMsg(events, fallbackText) {
    clearHero();
    const row = document.createElement("div");
    row.className = "row bot";
    row.innerHTML = `<div class="inner"><div class="mav"><img src="ghogemava.jpg" alt=""/></div>
      <div class="body" style="flex:1;min-width:0;">
        <div class="role">GhoGem</div>
        <div class="stream"></div>
      </div></div>`;
    $("#msgs").appendChild(row);
    const streamEl = row.querySelector(".stream");
    let actionsWrap = null;

    function openActionsWrap() {
      actionsWrap = document.createElement("div");
      actionsWrap.className = "agent-actions";
      actionsWrap.innerHTML = `
        <button type="button" class="agent-actions-head">
          <span class="agent-actions-chevron">⌄</span>
          <span class="agent-actions-title">Действия</span>
          <span class="agent-actions-count">0</span>
        </button>
        <div class="agent-actions-body"></div>
      `;
      streamEl.appendChild(actionsWrap);
      actionsWrap.querySelector(".agent-actions-head").addEventListener("click", () => {
        actionsWrap.classList.toggle("open");
      });
      return actionsWrap;
    }

    (events || []).forEach((ev) => {
      if (ev.type === "text") {
        actionsWrap = null;
        if (!ev.raw) return;
        const txtEl = document.createElement("div");
        txtEl.className = "txt";
        txtEl.innerHTML = renderMarkdown(ev.raw);
        streamEl.appendChild(txtEl);
        enhanceCode(txtEl);
      } else if (ev.type === "action") {
        if (!actionsWrap) openActionsWrap();
        const body = actionsWrap.querySelector(".agent-actions-body");
        const card = document.createElement("div");
        card.className = "action-card done";
        card.dataset.tool = ev.name;
        card._toolArgs = ev.args || {};
        card._toolResult = ev.resultPreview || "";
        card.innerHTML = `
          <div class="action-main">
            <span class="action-name">${esc(ev.text || ev.name)}</span>
            <span class="action-chevron">›</span>
          </div>
          <div class="action-details"></div>
        `;
        card.addEventListener("click", (e) => {
          e.stopPropagation();
          const details = card.querySelector(".action-details");
          if (!details) return;
          if (card.classList.contains("expanded")) { card.classList.remove("expanded"); return; }
          let argsHtml = "";
          try {
            const pretty = JSON.stringify(card._toolArgs, null, 2);
            if (pretty && pretty !== "{}") argsHtml = `<div class="action-detail-label">Параметры</div><pre>${esc(pretty)}</pre>`;
          } catch (_) {}
          const resultHtml = card._toolResult ? `<div class="action-detail-label">Результат</div><pre>${esc(card._toolResult)}</pre>` : "";
          details.innerHTML = argsHtml + resultHtml + (!argsHtml && !resultHtml ? `<div class="action-detail-empty">Нет подробностей</div>` : "");
          card.classList.add("expanded");
        });
        body.appendChild(card);
        const count = actionsWrap.querySelector(".agent-actions-count");
        if (count) count.textContent = String(body.querySelectorAll(".action-card").length);
      } else if (ev.type === "fallback") {
        actionsWrap = null;
        const el = document.createElement("div");
        el.className = "fallback-note";
        el.innerHTML = `<span class="fallback-icon">↻</span><span>${esc(ev.text)}</span>`;
        streamEl.appendChild(el);
      } else if (ev.type === "media") {
        actionsWrap = null;
        const url = API + "/files/raw?name=" + encodeURIComponent(ev.name) + "&init_data=" + encodeURIComponent(state.initData);
        const block = document.createElement("div");
        block.className = "media-block";
        if (ev.kind === "audio") {
          block.innerHTML = `<audio controls src="${escAttr(url)}"></audio><div class="media-cap">${esc(ev.name)}</div>`;
        } else if (ev.kind === "image") {
          block.innerHTML = `<img class="media-img" src="${escAttr(url)}" alt=""/><div class="media-cap">${esc(ev.name)}</div>`;
        } else {
          block.innerHTML = `<button type="button" class="media-file" data-open="${escAttr(ev.name)}">
            <svg class="ic sm" viewBox="0 0 24 24"><path d="M3 7.5A2.5 2.5 0 015.5 5H10l2 2h6.5A2.5 2.5 0 0121 9.5v7A2.5 2.5 0 0118.5 19h-13A2.5 2.5 0 013 16.5v-9z"/></svg>
            <span class="fname">${esc(ev.name)}</span></button>`;
        }
        streamEl.appendChild(block);
        const fileBtn = block.querySelector(".media-file");
        if (fileBtn) fileBtn.addEventListener("click", () => { openFileViewer(ev.name); });
        registerCanvasTab(ev.name);
      }
    });

    if (!streamEl.children.length && fallbackText) {
      const txtEl = document.createElement("div");
      txtEl.className = "txt";
      txtEl.innerHTML = renderMarkdown(fallbackText);
      streamEl.appendChild(txtEl);
    }
  }

  function updateChatTitle(text) {
    const chats = lsGetChats();
    const c = chats.find((x) => x.id === state.chatId);
    if (c && (c.title === "Новый чат" || !c.title)) {
      c.title = text.slice(0, 42);
      lsSaveChats(chats);
      renderChatList();
    }
  }

  // ═══════════════ FILES ═══════════════
  async function loadFiles() {
    const box = $("#fileList");
    if (!box) return;
    try {
      const data = await api("/files?init_data=" + encodeURIComponent(state.initData));
      const files = data.files || [];
      state.canvasFiles = files.map((f) => ({ filename: f.name, ext: f.ext }));
      renderCanvasTabs();
      $("#btnCanvasToggle").style.display = files.length ? "" : "none";
      if (!files.length) { box.innerHTML = '<div class="empty">Пока пусто</div>'; return; }
      box.innerHTML = files.map((f) => `
        <div class="fcard" data-name="${escAttr(f.name)}">
          <div class="nm">${esc(f.name)}</div>
          <div class="factions">
            <button type="button" class="chip act-open">Открыть</button>
            <a class="chip act-dl" download href="${escAttr(API + "/files/raw?name=" + encodeURIComponent(f.name) + "&init_data=" + encodeURIComponent(state.initData))}">Скачать</a>
          </div>
        </div>`).join("");
      box.querySelectorAll(".fcard").forEach((card) => {
        const name = card.getAttribute("data-name");
        card.querySelector(".act-open").addEventListener("click", (e) => { e.stopPropagation(); openFileViewer(name); });
      });
    } catch (e) {
      box.innerHTML = '<div class="empty">' + esc(e.message) + "</div>";
    }
  }

  // Единый файловый просмотрщик внутри сайта: html -> iframe, код/текст ->
  // подсветка, картинка/аудио -> нативный рендер. Скачивание — отдельной
  // кнопкой с настоящим download, не window.open по прямой ссылке.
  const CODE_EXT = new Set(["py", "js", "ts", "css", "json", "md", "txt", "yml", "yaml", "sh", "c", "cpp", "java", "go", "rs"]);
  const IMAGE_EXT = new Set(["png", "jpg", "jpeg", "webp", "gif", "svg"]);
  const AUDIO_EXT = new Set(["mp3", "ogg", "wav", "m4a", "webm"]);

  async function openFileViewer(name) {
    state.previewOrigin = $("#view-files").classList.contains("active") ? "files" : "chat";
    const ext = extOf(name);
    $("#previewName").textContent = name;
    $("#previewDownload").href = API + "/files/raw?name=" + encodeURIComponent(name) + "&init_data=" + encodeURIComponent(state.initData);
    $("#previewFrame").style.display = "none";
    $("#previewCodeBox").style.display = "none";
    $("#previewMediaBox").style.display = "none";
    showView("preview");

    if (ext === "html" || ext === "htm") {
      $("#previewFrame").style.display = "block";
      $("#previewFrame").src = API + "/files/preview?name=" + encodeURIComponent(name) + "&init_data=" + encodeURIComponent(state.initData);
    } else if (IMAGE_EXT.has(ext)) {
      const box = $("#previewMediaBox");
      box.style.display = "flex";
      box.innerHTML = `<img src="${escAttr(API + "/files/raw?name=" + encodeURIComponent(name) + "&init_data=" + encodeURIComponent(state.initData))}" alt=""/>`;
    } else if (AUDIO_EXT.has(ext)) {
      const box = $("#previewMediaBox");
      box.style.display = "flex";
      box.innerHTML = `<audio controls autoplay src="${escAttr(API + "/files/raw?name=" + encodeURIComponent(name) + "&init_data=" + encodeURIComponent(state.initData))}"></audio>`;
    } else {
      // код / текст / всё остальное — пытаемся показать как текст с подсветкой
      const box = $("#previewCodeBox");
      const inner = $("#previewCodeInner");
      box.style.display = "block";
      inner.textContent = "Загрузка…";
      try {
        const data = await api("/files/content?name=" + encodeURIComponent(name) + "&init_data=" + encodeURIComponent(state.initData));
        inner.className = CODE_EXT.has(ext) ? "language-" + ext : "";
        inner.textContent = data.content;
        if (window.hljs) { inner.dataset.enhanced = ""; hljs.highlightElement(inner); }
      } catch (e) {
        inner.textContent = "Не удалось открыть файл: " + e.message;
      }
    }
  }

  // ═══════════════ CANVAS ═══════════════
  function renderCanvasTabs() {
    const box = $("#canvasTabs");
    if (!box) return;
    box.innerHTML = state.canvasFiles.map((f) => {
      const active = f.filename === state.activeCanvasFile ? " active" : "";
      return `<button type="button" class="canvas-tab${active}" data-name="${escAttr(f.filename)}">${esc(f.filename)}</button>`;
    }).join("");
    box.querySelectorAll(".canvas-tab").forEach((btn) => {
      btn.addEventListener("click", () => openCanvasFile(btn.getAttribute("data-name")));
    });
  }

  async function openCanvasFile(filename) {
    if (!state.canvasFiles.find((f) => f.filename === filename)) {
      state.canvasFiles.push({ filename, ext: extOf(filename) });
    }
    state.activeCanvasFile = filename;
    setCanvasOpen(true);
    renderCanvasTabs();
    const ext = extOf(filename);
    const canPreview = PREVIEWABLE.has(ext);
    $("#canvasPreview").style.display = canPreview ? "" : "none";
    if (!canPreview) state.canvasMode = "code";
    $("#canvasDl").href = API + "/files/raw?name=" + encodeURIComponent(filename) + "&init_data=" + encodeURIComponent(state.initData);
    if (state.canvasMode === "preview" && canPreview) showCanvasPreview(filename);
    else await showCanvasCode(filename);
    updateCanvasModeButtons();
  }

  async function showCanvasCode(filename) {
    $("#canvasFrame").style.display = "none";
    $("#canvasCodeBox").style.display = "block";
    const inner = $("#canvasCodeInner");
    inner.textContent = "Загрузка…";
    try {
      const data = await api("/files/content?name=" + encodeURIComponent(filename) + "&init_data=" + encodeURIComponent(state.initData));
      const ext = extOf(filename);
      inner.className = ext ? "language-" + ext : "";
      inner.textContent = data.content;
      if (window.hljs) { inner.dataset.enhanced = ""; hljs.highlightElement(inner); }
    } catch (e) {
      inner.textContent = "Не удалось загрузить файл: " + e.message;
    }
  }
  function showCanvasPreview(filename) {
    $("#canvasCodeBox").style.display = "none";
    $("#canvasFrame").style.display = "block";
    $("#canvasFrame").src = API + "/files/preview?name=" + encodeURIComponent(filename) + "&init_data=" + encodeURIComponent(state.initData);
  }
  function updateCanvasModeButtons() {
    $("#canvasCode").classList.toggle("active", state.canvasMode === "code");
    $("#canvasPreview").classList.toggle("active", state.canvasMode === "preview");
  }
  function setCanvasOpen(open) {
    $("#workspace").classList.toggle("canvas-open", open);
    $("#btnCanvasToggle").style.display = state.canvasFiles.length ? "" : "none";
  }
  $("#canvasCode").addEventListener("click", () => { state.canvasMode = "code"; if (state.activeCanvasFile) showCanvasCode(state.activeCanvasFile); updateCanvasModeButtons(); });
  $("#canvasPreview").addEventListener("click", () => { state.canvasMode = "preview"; if (state.activeCanvasFile) showCanvasPreview(state.activeCanvasFile); updateCanvasModeButtons(); });
  $("#canvasClose").addEventListener("click", () => setCanvasOpen(false));
  $("#btnCanvasToggle").addEventListener("click", () => {
    if ($("#workspace").classList.contains("canvas-open")) { setCanvasOpen(false); return; }
    if (state.activeCanvasFile) openCanvasFile(state.activeCanvasFile);
    else if (state.canvasFiles.length) openCanvasFile(state.canvasFiles[0].filename);
  });

  // ═══════════════ MARKDOWN RENDER ═══════════════
  if (window.marked) marked.setOptions({ breaks: true, gfm: true });
  function renderMarkdown(raw) {
    let text = (raw || "").replace(/<think>[\s\S]*?<\/think>/gi, "").replace(/<\/?think>/gi, "");
    let html = window.marked ? marked.parse(text) : esc(text).replace(/\n/g, "<br>");
    if (window.DOMPurify) html = DOMPurify.sanitize(html, { ADD_ATTR: ["target"] });
    return html;
  }
  function enhanceCode(container) {
    container.querySelectorAll("pre code").forEach((block) => {
      if (block.dataset.enhanced) return;
      block.dataset.enhanced = "1";
      try { if (window.hljs) hljs.highlightElement(block); } catch (e) {}
    });
  }

  // ═══════════════ MESSAGE RENDERING ═══════════════
  function clearHero() { const h = $("#hero"); if (h) h.remove(); }

  function attachMsgActions(bodyEl, role, getText) {
    const bar = document.createElement("div");
    bar.className = "msg-actions";
    bar.innerHTML =
      `<button type="button" class="msg-act" data-act="copy" title="Копировать">
        <svg class="ic sm" viewBox="0 0 24 24"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a2 2 0 012-2h10"/></svg>
        <span>Копировать</span>
      </button>` +
      (role === "user"
        ? `<button type="button" class="msg-act" data-act="retry" title="Отправить снова">
            <svg class="ic sm" viewBox="0 0 24 24"><path d="M3 12a9 9 0 0115.5-6.4M21 3v6h-6M21 12a9 9 0 01-15.5 6.4M3 21v-6h6"/></svg>
            <span>Ещё раз</span>
          </button>`
        : `<button type="button" class="msg-act" data-act="retry" title="Попробовать снова">
            <svg class="ic sm" viewBox="0 0 24 24"><path d="M3 12a9 9 0 0115.5-6.4M21 3v6h-6M21 12a9 9 0 01-15.5 6.4M3 21v-6h6"/></svg>
            <span>Ещё раз</span>
          </button>`);
    bar.querySelector('[data-act="copy"]').addEventListener("click", async (e) => {
      e.stopPropagation();
      const t = typeof getText === "function" ? getText() : String(getText || "");
      try {
        await navigator.clipboard.writeText(t);
        const span = bar.querySelector('[data-act="copy"] span');
        if (span) { const old = span.textContent; span.textContent = "Скопировано"; setTimeout(() => { span.textContent = old; }, 1200); }
      } catch (_) {}
    });
    bar.querySelector('[data-act="retry"]').addEventListener("click", (e) => {
      e.stopPropagation();
      const t = typeof getText === "function" ? getText() : String(getText || "");
      if (role === "user") send(t);
      else {
        // для ответа ассистента — переотправляем последний user из localStorage
        const msgs = lsGetMsgs(state.chatId);
        for (let i = msgs.length - 1; i >= 0; i--) {
          if (msgs[i].role === "user" && msgs[i].text) { send(msgs[i].text); return; }
        }
      }
    });
    bodyEl.appendChild(bar);
  }

  function addMsg(role, text, save, animate) {
    clearHero();
    const row = document.createElement("div");
    row.className = "row " + (role === "user" ? "user" : "bot");
    const who = role === "user" ? "Вы" : "GhoGem";
    const av = role === "user" ? "Ты" : '<img src="ghogemava.jpg" alt=""/>';
    row.innerHTML = `<div class="inner"><div class="mav">${av}</div>
      <div class="body"><div class="role">${who}</div><div class="txt"></div></div></div>`;
    const txtEl = row.querySelector(".txt");
    const bodyEl = row.querySelector(".body");
    if (role === "user") txtEl.textContent = text;
    else { txtEl.innerHTML = renderMarkdown(text); enhanceCode(txtEl); }
    attachMsgActions(bodyEl, role, () => text);
    $("#msgs").appendChild(row);
    $("#msgs").scrollTop = $("#msgs").scrollHeight;
    if (save !== false && !isServerStore()) { lsAppendMsg(state.chatId, role, text); if (role === "user") updateChatTitle(text); }
    return txtEl;
  }

  function createLiveAssistantMsg() {
    clearHero();
    const row = document.createElement("div");
    row.className = "row bot";
    row.innerHTML = `<div class="inner"><div class="mav"><img src="ghogemava.jpg" alt=""/></div>
      <div class="body" style="flex:1;min-width:0;">
        <div class="role">GhoGem</div>
        <div class="think-block" style="display:none"></div>
        <div class="stream"></div>
      </div></div>`;
    $("#msgs").appendChild(row);
    $("#msgs").scrollTop = $("#msgs").scrollHeight;

    const bodyEl = row.querySelector(".body");
    const thinkEl = row.querySelector(".think-block");
    const streamEl = row.querySelector(".stream");
    let curTextEl = null; // текущий открытый текстовый сегмент, куда пишутся токены
    let curActionsWrap = null; // текущий открытый .agent-actions блок — сбрасывается
                                // при появлении текста, чтобы actions после текста
                                // не утекали в старый collapsible сверху сообщения

    function openTextSegment() {
      curTextEl = document.createElement("div");
      curTextEl.className = "txt";
      streamEl.appendChild(curTextEl);
      curActionsWrap = null; // следующий tool должен открыть НОВЫЙ блок действий
      liveObj.events.push({ type: "text", raw: "" });
      return curTextEl;
    }

    const liveObj = {
      row, thinkEl, streamEl,
      thinkText: "", answerText: "",
      events: [], // журнал событий сообщения — сохраняется в localStorage,
                  // чтобы после перезагрузки страницы можно было заново
                  // собрать те же action-карточки/медиа/fallback, а не
                  // просто голый текст ответа
      startThinking() {
        thinkEl.style.display = "block";
        thinkEl.classList.add("open");
        thinkEl.innerHTML = '<div class="think-head"><span class="dot"></span><span>Думает…</span></div><div class="think-body"></div>';
        thinkEl.querySelector(".think-head").addEventListener("click", () => thinkEl.classList.toggle("open"));
      },
      appendThinking(t) {
        this.thinkText += t;
        const b = thinkEl.querySelector(".think-body");
        if (b) b.textContent = this.thinkText;
        $("#msgs").scrollTop = $("#msgs").scrollHeight;
      },
      endThinking() {
        thinkEl.classList.remove("open"); thinkEl.classList.add("done");
        const h = thinkEl.querySelector(".think-head span:last-child");
        if (h) h.textContent = "Думал";
      },
      // карточка вызова инструмента вставляется ровно там, где модель
      // сейчас находится в потоке текста — следующий текстовый сегмент
      // откроется уже ПОСЛЕ неё
      addAction(name, text, args = {}, resultPreview = "") {
        curTextEl = null;

        let wrap = curActionsWrap;

        if (!wrap) {
          wrap = document.createElement("div");
          wrap.className = "agent-actions";

          wrap.innerHTML = `
            <button type="button" class="agent-actions-head">
              <span class="agent-actions-chevron">⌄</span>
              <span class="agent-actions-title">Действия</span>
              <span class="agent-actions-count">1</span>
            </button>
            <div class="agent-actions-body"></div>
          `;

          streamEl.appendChild(wrap);
          curActionsWrap = wrap;

          wrap.querySelector(".agent-actions-head").addEventListener("click", () => {
            wrap.classList.toggle("open");
          });
        }

        const body = wrap.querySelector(".agent-actions-body");

        const card = document.createElement("div");
        card.className = "action-card pending";
        card.dataset.tool = name;
        card._toolArgs = args || {};
        card._toolResult = resultPreview || "";

        const evEntry = { type: "action", name, text: text || name, args: args || {}, resultPreview: resultPreview || "" };
        this.events.push(evEntry);
        card._logEntry = evEntry;

        card.innerHTML = `
          <div class="action-main">
            <span class="spin"></span>
            <span class="action-name">${esc(text || name)}</span>
            <span class="action-chevron">›</span>
          </div>
          <div class="action-details"></div>
        `;

        body.appendChild(card);

        const count = wrap.querySelector(".agent-actions-count");
        if (count) {
          count.textContent = String(
            body.querySelectorAll(".action-card").length
          );
        }

        card.addEventListener("click", (e) => {
          e.stopPropagation();

          const details = card.querySelector(".action-details");
          if (!details) return;

          if (card.classList.contains("expanded")) {
            card.classList.remove("expanded");
            return;
          }

          const argsObj = card._toolArgs || {};
          const result = card._toolResult || "";

          let argsHtml = "";

          try {
            const pretty = JSON.stringify(argsObj, null, 2);
            if (pretty && pretty !== "{}") {
              argsHtml = `
                <div class="action-detail-label">Параметры</div>
                <pre>${esc(pretty)}</pre>
              `;
            }
          } catch (_) {}

          const resultHtml = result
            ? `
              <div class="action-detail-label">Результат</div>
              <pre>${esc(result)}</pre>
            `
            : "";

          details.innerHTML =
            argsHtml +
            resultHtml +
            (!argsHtml && !resultHtml
              ? `<div class="action-detail-empty">Нет подробностей</div>`
              : "");

          card.classList.add("expanded");
        });

        $("#msgs").scrollTop = $("#msgs").scrollHeight;
        return card;
      },

      resolveAction(card, text, resultPreview = "") {
        if (!card) return;

        card.classList.remove("pending");
        card.classList.add("done");

        const nameEl = card.querySelector(".action-name");
        if (nameEl) nameEl.textContent = text || card.dataset.tool || "Инструмент";

        const spin = card.querySelector(".spin");
        if (spin) spin.remove();

        if (resultPreview != null) {
          card._toolResult = String(resultPreview);
        }

        if (card._logEntry) {
          card._logEntry.text = text || card._logEntry.text;
          card._logEntry.resultPreview = resultPreview || card._logEntry.resultPreview;
        }

        const wrap = card.closest(".agent-actions");
        if (wrap) {
          const body = wrap.querySelector(".agent-actions-body");
          const count = wrap.querySelector(".agent-actions-count");

          if (count && body) {
            count.textContent = String(
              body.querySelectorAll(".action-card").length
            );
          }
        }
      },

      // Fallback-переключение модели — НЕ обычный tool call, поэтому не
      // идёт в тот же collapsible "Действия", а рисуется отдельной плашкой,
      // видимой сразу (без раскрытия), прямо в месте где произошло.
      addFallback(text) {
        curTextEl = null;
        curActionsWrap = null;
        const el = document.createElement("div");
        el.className = "fallback-note";
        el.innerHTML = `<span class="fallback-icon">↻</span><span>${esc(text)}</span>`;
        streamEl.appendChild(el);
        this.events.push({ type: "fallback", text });
        $("#msgs").scrollTop = $("#msgs").scrollHeight;
      },

      addMedia(kind, name) {
        curTextEl = null; // медиа тоже разрывает текстовый поток
        curActionsWrap = null; // и группу действий — следующий tool откроет новую
        const url = API + "/files/raw?name=" + encodeURIComponent(name) + "&init_data=" + encodeURIComponent(state.initData);
        const block = document.createElement("div");
        block.className = "media-block";
        if (kind === "audio") {
          block.innerHTML = `<audio controls src="${escAttr(url)}"></audio><div class="media-cap">${esc(name)}</div>`;
        } else if (kind === "image") {
          block.innerHTML = `<img class="media-img" src="${escAttr(url)}" alt=""/><div class="media-cap">${esc(name)}</div>`;
        } else {
          block.innerHTML = `<button type="button" class="media-file" data-open="${escAttr(name)}">
            <svg class="ic sm" viewBox="0 0 24 24"><path d="M3 7.5A2.5 2.5 0 015.5 5H10l2 2h6.5A2.5 2.5 0 0121 9.5v7A2.5 2.5 0 0118.5 19h-13A2.5 2.5 0 013 16.5v-9z"/></svg>
            <span class="fname">${esc(name)}</span></button>`;
        }
        streamEl.appendChild(block);
        const fileBtn = block.querySelector(".media-file");
        if (fileBtn) fileBtn.addEventListener("click", () => { openFileViewer(name); });
        this.events.push({ type: "media", kind, name });
        $("#msgs").scrollTop = $("#msgs").scrollHeight;
        state.canvasFiles.length || loadFiles();
        registerCanvasTab(name);
      },
      appendToken(t) {
        this.answerText += t;
        if (!curTextEl) curTextEl = openTextSegment();
        curTextEl.dataset.raw = (curTextEl.dataset.raw || "") + t;
        curTextEl.innerHTML = renderMarkdown(curTextEl.dataset.raw);
        enhanceCode(curTextEl);
        const lastEv = this.events[this.events.length - 1];
        if (lastEv && lastEv.type === "text") lastEv.raw = curTextEl.dataset.raw;
        $("#msgs").scrollTop = $("#msgs").scrollHeight;
      },
      finalize() {
        if (curTextEl) { curTextEl.innerHTML = renderMarkdown(curTextEl.dataset.raw || ""); enhanceCode(curTextEl); }
        // контекстное меню под ответом (один раз)
        if (!bodyEl.querySelector(".msg-actions")) {
          attachMsgActions(bodyEl, "assistant", () => this.answerText || "");
        }
        $("#msgs").scrollTop = $("#msgs").scrollHeight;
      },
    };
    return liveObj;
  }

  function registerCanvasTab(name) {
    if (!state.canvasFiles.find((f) => f.filename === name)) {
      state.canvasFiles.push({ filename: name, ext: extOf(name) });
      renderCanvasTabs();
      $("#btnCanvasToggle").style.display = "";
    }
  }

  function renderSugs() {
    const sugs = [
      ["Объясни квантовые вычисления простыми словами", "Сложная тема"],
      ["Создай snake.html — змейка на canvas", "HTML-игра"],
      ["Что нового в ИИ на этой неделе?", "Новости + поиск"],
    ];
    const sg = $("#sugs");
    if (!sg) return;
    sg.innerHTML = sugs.map(([q, t]) => `<button type="button" class="sug" data-q="${escAttr(q)}">${esc(t)}</button>`).join("");
    sg.querySelectorAll(".sug").forEach((b) => b.addEventListener("click", () => send(b.getAttribute("data-q"))));
  }

  // ═══════════════ WEBSOCKET ═══════════════
  let wsReconnectDelay = 1000;
  let wsReconnectTimer = null;

  function setConnDot(status) {
    const dot = $("#connDot");
    if (!dot) return;
    dot.classList.remove("live", "down");
    if (status === "live") dot.classList.add("live");
    if (status === "down") dot.classList.add("down");
  }

  function connectWS() {
    if (state.ws && (state.ws.readyState === WebSocket.OPEN || state.ws.readyState === WebSocket.CONNECTING)) return;
    const ws = new WebSocket(WS_URL);
    state.ws = ws;
    state.wsReady = false;
    setConnDot("connecting");

    ws.addEventListener("open", () => {
      state.wsReady = true;
      wsReconnectDelay = 1000;
      setConnDot("live");
      while (state.wsQueue.length) ws.send(JSON.stringify(state.wsQueue.shift()));
    });
    ws.addEventListener("message", (evt) => {
      let data; try { data = JSON.parse(evt.data); } catch (e) { return; }
      handleWSEvent(data);
    });
    ws.addEventListener("close", () => {
      state.wsReady = false; state.ws = null; setConnDot("down");
      if (state.sending && state.liveMsg) {
        state.liveMsg.appendToken("\n\n[Соединение потеряно, переподключаюсь…]");
        state.liveMsg.finalize();
        if (!isServerStore()) lsAppendMsg(state.chatId, "assistant", state.liveMsg.answerText, state.liveMsg.events);
        state.sending = false; syncSend();
      }
      scheduleReconnect();
    });
    ws.addEventListener("error", () => ws.close());
  }
  function scheduleReconnect() {
    clearTimeout(wsReconnectTimer);
    wsReconnectTimer = setTimeout(() => { connectWS(); wsReconnectDelay = Math.min(wsReconnectDelay * 1.6, 15000); }, wsReconnectDelay);
  }
  function wsSend(payload) {
    const token = gsToken();
    if (token) payload.gs_token = token;
    if (state.ws && state.wsReady) state.ws.send(JSON.stringify(payload));
    else { state.wsQueue.push(payload); connectWS(); }
  }

  function handleWSEvent(data) {
    const live = state.liveMsg;
    if (!live) return;
    switch (data.type) {
      case "thinking_start": live.startThinking(); break;
      case "thinking": live.appendThinking(data.text || ""); break;
      case "thinking_end": live.endThinking(); break;
      case "token": live.appendToken(data.text || ""); break;
      case "action": {
        const key = data.name + "|" + JSON.stringify(data.args || {});

        if (data.phase === "start") {
          const card = live.addAction(
            data.name,
            data.text,
            data.args || {},
            ""
          );

          state.pendingActions.set(key, card);
        } else {
          const card =
            state.pendingActions.get(key) ||
            live.addAction(
              data.name,
              data.text,
              data.args || {},
              data.result_preview || ""
            );

          live.resolveAction(
            card,
            data.text,
            data.result_preview || ""
          );

          state.pendingActions.delete(key);
        }

        break;
      }
      case "media": live.addMedia(data.kind, data.name); break;
      case "fallback": {
        live.addFallback(data.text || `${data.from || "?"} в лимите — переключаюсь на ${data.to || "?"}`);
        // полный key (groq:...) — сохранить как выбранную на следующие промпты
        const newKey = data.model || data.to_key;
        if (newKey) saveSelectedModel(newKey);
        if (data.from_key) {
          const oldProv = String(data.from_key).split(":")[0];
          if (oldProv) markLimited(oldProv, 15);
        }
        break;
      }
      case "cancelled":
        // сообщение НЕ удаляем — дописываем статус и сохраняем
        live.appendToken("\n\n⏹ Вы остановили генерацию");
        live.finalize();
        if (!isServerStore()) lsAppendMsg(state.chatId, "assistant", live.answerText, live.events);
        finishTurn();
        break;
      case "done":
        if (data.model) saveSelectedModel(data.model);
        live.finalize();
        if (!isServerStore()) lsAppendMsg(state.chatId, "assistant", live.answerText, live.events);
        finishTurn();
        break;
    }
  }
  function finishTurn() {
    state.sending = false; state.liveMsg = null; state.pendingActions = null;
    syncSend();
  }

  // ═══════════════ SEND ═══════════════
  const SEND_ICON = '<svg class="ic" viewBox="0 0 24 24"><path d="M5 12h14M13 6l6 6-6 6"/></svg>';
  const STOP_ICON = '<span class="gen-orb" aria-hidden="true"></span>';
  function syncSend() {
    const btn = $("#btnSend");
    if (!btn) return;
    if (state.sending) {
      // во время генерации кнопка = стоп (креативный «орб», не серая disabled)
      btn.disabled = false;
      btn.classList.add("stop", "gen-active");
      btn.setAttribute("aria-label", "Остановить");
      btn.title = "Остановить генерацию";
      if (!btn.dataset.mode || btn.dataset.mode !== "stop") {
        btn.dataset.mode = "stop";
        btn.innerHTML = STOP_ICON;
      }
    } else {
      btn.classList.remove("stop", "gen-active");
      btn.setAttribute("aria-label", "Отправить");
      btn.title = "Отправить";
      if (btn.dataset.mode !== "send") {
        btn.dataset.mode = "send";
        btn.innerHTML = SEND_ICON;
      }
      const has = !!($("#input").value || "").trim();
      btn.disabled = !state.pageReady || !has;
    }
  }
  function grow(ta) { ta.style.height = "auto"; ta.style.height = Math.min(ta.scrollHeight, 160) + "px"; }

  function send(pre) {
    if (!state.pageReady) { showLoadingTip(); return; }
    const ta = $("#input");
    const text = (pre != null ? pre : ta.value || "").trim();
    if (!text || state.sending) return;
    const prov = (state.model || "").split(":")[0];
    if (isLimited(prov)) { addMsg("assistant", "Провайдер " + prov + " в лимите. Выбери другую модель.", false); showView("models"); return; }

    if (!state.context && !isServerStore()) ensureChat();
    state.sending = true; syncSend();
    if (pre == null) { ta.value = ""; grow(ta); }
    addMsg("user", text);

    state.liveMsg = createLiveAssistantMsg();
    state.pendingActions = new Map();

    wsSend({
      type: "message", text, model: state.model,
      web_search: state.webSearch, force_tts: state.forceTts,
      chat_id: state.chatId, context: state.context, init_data: state.initData,
    });
    if (state.webSearch) { state.webSearch = false; $("#btnSearch").setAttribute("aria-pressed", "false"); }
    if (state.forceTts) { state.forceTts = false; $("#btnTts").setAttribute("aria-pressed", "false"); }
  }

  let loadingTipTimer = null;
  function showLoadingTip() {
    let tip = $("#loadingTip");
    if (!tip) {
      tip = document.createElement("div");
      tip.id = "loadingTip";
      tip.className = "loading-tip";
      tip.textContent = "Страница ещё загружается — кнопка станет активной, когда всё будет готово";
      document.body.appendChild(tip);
    }
    tip.classList.add("show");
    clearTimeout(loadingTipTimer);
    loadingTipTimer = setTimeout(() => tip.classList.remove("show"), 2200);
  }

  function markPageReady() {
    state.pageReady = true;
    syncSend();
    const tip = $("#loadingTip");
    if (tip) tip.remove();
  }

  // ═══════════════ UPLOAD ═══════════════
  async function uploadFile(file) {
    const fd = new FormData();
    fd.append("file", file);
    const q = state.initData ? "?init_data=" + encodeURIComponent(state.initData) : "";
    const headers = {};
    if (state.initData) headers["X-Tg-Init-Data"] = state.initData;
    const token = gsToken();
    if (token) headers["X-Gs-Token"] = token;
    const res = await fetch(API + "/files/upload" + q, { method: "POST", body: fd, headers });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.detail || "upload failed");
    return data;
  }

  // ═══════════════ SETTINGS ═══════════════
  function applyPrefs() {
    setMeshEnabled(!!prefs.mesh);
    document.body.classList.toggle("density-compact", prefs.density === "compact");
    $("#meshToggle").classList.toggle("active", !!prefs.mesh);
    $("#enterToggle").classList.toggle("active", !!prefs.enterSend);
    $$("#densitySwitch button").forEach((b) => b.classList.toggle("active", b.getAttribute("data-value") === prefs.density));
  }
  function savePrefs() { lsSavePrefs(prefs); applyPrefs(); }

  // ═══════════════ EVENT BINDINGS ═══════════════
  $("#btnSend").addEventListener("click", () => {
    if (!state.pageReady) { showLoadingTip(); return; }
    if (state.sending) {
      // локально сразу помечаем — сервер пришлёт cancelled, но UX мгновенный
      wsSend({ type: "stop" });
      if (state.liveMsg) {
        state.liveMsg.appendToken("\n\n⏹ Вы остановили генерацию");
        state.liveMsg.finalize();
        if (!isServerStore()) lsAppendMsg(state.chatId, "assistant", state.liveMsg.answerText, state.liveMsg.events);
      }
      finishTurn();
      return;
    }
    send();
  });
  // disabled-кнопка не всегда отдаёт click в мобильных браузерах —
  // ловим тап по всей области композера, пока страница ещё грузится
  $(".box").addEventListener("pointerdown", (e) => {
    if (!state.pageReady && (e.target.closest("#btnSend") || e.target.closest("#input"))) showLoadingTip();
  });
  $("#input").addEventListener("input", (e) => { grow(e.target); syncSend(); });
  $("#input").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && prefs.enterSend) { e.preventDefault(); send(); }
    else if (e.key === "Enter" && (e.ctrlKey || e.metaKey) && !prefs.enterSend) { e.preventDefault(); send(); }
  });
  $("#btnSearch").addEventListener("click", () => {
    state.webSearch = !state.webSearch;
    $("#btnSearch").setAttribute("aria-pressed", state.webSearch ? "true" : "false");
  });
  $("#btnTts").addEventListener("click", () => {
    state.forceTts = !state.forceTts;
    $("#btnTts").setAttribute("aria-pressed", state.forceTts ? "true" : "false");
  });

  $("#btnNew").addEventListener("click", async () => {
    closeSb();
    try {
      if (isServerStore()) {
        const d = await api("/chats/new", { method: "POST" });
        state.serverChats.unshift({ id: d.chat_id, title: "Новый чат" });
        await switchChat(d.chat_id);
        return;
      }
      state.context = "";
      const id = uuid();
      const chats = lsGetChats();
      chats.unshift({ id, title: "Новый чат", createdAt: Date.now() });
      lsSaveChats(chats);
      await switchChat(id);
    } catch (e) { console.error("new chat failed", e); }
  });

  $("#modelBtn").addEventListener("click", () => { showView("models"); loadModels(); });
  // раньше только openSb — повторный тап по бургеру не закрывал меню
  $("#btnMenu").addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    toggleSb();
  });
  const bdEl = $("#backdrop");
  if (bdEl) {
    const closeFromBd = (e) => { e.preventDefault(); e.stopPropagation(); closeSb(); };
    bdEl.addEventListener("click", closeFromBd);
    bdEl.addEventListener("pointerdown", closeFromBd);
  }
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeSb(); });
  // тап вне сайдбара закрывает (мобильный WebView часто ест click на backdrop)
  document.addEventListener("pointerdown", (e) => {
    const sb = $("#sidebar");
    if (!sb || !sb.classList.contains("open")) return;
    if (e.target.closest("#sidebar") || e.target.closest("#btnMenu")) return;
    closeSb();
  }, true);
  $$(".sb-item").forEach((b) => b.addEventListener("click", () => {
    const v = b.getAttribute("data-view");
    closeSb();
    try {
      showView(v);
      if (v === "files") loadFiles();
      if (v === "models") loadModels();
      if (v === "ranking") loadRanking();
      if (v === "contexts") loadContexts();
    } catch (e) { console.error("sb-item nav failed", e); }
  }));
  $("#btnBackModels").addEventListener("click", () => showView("chat"));
  $("#btnBackRanking").addEventListener("click", () => showView("chat"));
  $("#btnBackFiles").addEventListener("click", () => showView("chat"));
  $("#btnBackContexts").addEventListener("click", () => showView("chat"));
  $("#btnBackSettings").addEventListener("click", () => showView("chat"));
  $("#btnRefreshFiles").addEventListener("click", loadFiles);
  $("#btnRefreshRanking").addEventListener("click", loadRanking);
  $("#ratingFilters").querySelectorAll("[data-rating-filter]").forEach((button) => {
    button.addEventListener("click", () => {
      state.rankingFilter = button.getAttribute("data-rating-filter") || "all";
      renderRatingFilters();
      renderRanking();
    });
  });
  $("#btnClosePreview").addEventListener("click", () => showView(state.previewOrigin || "files"));

  // plus menu (rotates into X)
  const plusBtn = $("#btnPlus"), plusMenu = $("#plusMenu");
  function closePlusMenu() { plusMenu.classList.remove("open"); plusBtn.setAttribute("aria-expanded", "false"); }
  function togglePlusMenu() {
    const open = plusMenu.classList.toggle("open");
    plusBtn.setAttribute("aria-expanded", open ? "true" : "false");
  }
  plusBtn.addEventListener("click", (e) => { e.stopPropagation(); togglePlusMenu(); });
  document.addEventListener("click", (e) => { if (!plusMenu.contains(e.target) && e.target !== plusBtn) closePlusMenu(); });
  $("#itemFile").addEventListener("click", () => { closePlusMenu(); $("#fileInput").accept = ".pdf,.txt,.py,.html,.js,.css,.json,.md"; $("#fileInput").click(); });
  $("#itemImage").addEventListener("click", () => { closePlusMenu(); $("#fileInput").accept = "image/*"; $("#fileInput").click(); });
  $("#itemAudio").addEventListener("click", (e) => { e.stopPropagation(); /* locked — premium only, сайт пока без аккаунтов */ });

  $("#fileInput").addEventListener("change", async (e) => {
    const file = e.target.files && e.target.files[0];
    e.target.value = "";
    if (!file) return;
    if (!isServerStore()) ensureChat();
    addMsg("user", "Прикреплён файл: " + file.name);
    const statusEl = addMsg("assistant", "Загружаю…", false);
    try {
      const up = await uploadFile(file);
      const note = up.kind === "image" ? "Можешь написать «что на фото?»" : up.kind === "audio" ? "Можешь написать «расшифруй аудио»" : "Файл сохранён";
      statusEl.textContent = up.name + " — " + note;
      if (!isServerStore()) lsAppendMsg(state.chatId, "assistant", statusEl.textContent);
      loadFiles();
      registerCanvasTab(up.name);
    } catch (err) {
      statusEl.textContent = "Ошибка загрузки: " + err.message;
      if (!isServerStore()) lsAppendMsg(state.chatId, "assistant", statusEl.textContent);
    }
  });

  // settings
  $("#meshToggle").addEventListener("click", () => { prefs.mesh = !prefs.mesh; savePrefs(); });
  $("#enterToggle").addEventListener("click", () => { prefs.enterSend = !prefs.enterSend; savePrefs(); });
  $$("#densitySwitch button").forEach((b) => b.addEventListener("click", () => { prefs.density = b.getAttribute("data-value"); savePrefs(); }));
  $("#btnResetLocal").addEventListener("click", () => {
    if (!confirm("Удалить все локальные чаты и файлы на этом устройстве?")) return;
    lsGetChats().forEach((c) => { try { localStorage.removeItem(LS_MSGS_PREFIX + c.id); } catch (e) {} });
    lsSaveChats([]);
    if (isServerStore()) {
      acct.notice = "Локальные гостевые чаты очищены";
      renderAccount();
      showView("chat");
      return;
    }
    state.chatId = null;
    ensureChat();
    renderChatList();
    renderMessagesFromLocal();
    showView("chat");
  });

  // ═══════════════ MOBILE KEYBOARD / VIEWPORT ═══════════════
  // 100dvh не везде корректно ужимается когда открывается мобильная
  // клавиатура (особенно Chrome Android) — используем visualViewport,
  // если доступен, чтобы composer оставался в зоне видимости.
  function syncViewportHeight() {
    const h = (window.visualViewport && window.visualViewport.height) || window.innerHeight;
    document.documentElement.style.setProperty("--vvh", h + "px");
  }
  if (window.visualViewport) {
    window.visualViewport.addEventListener("resize", syncViewportHeight);
    window.visualViewport.addEventListener("scroll", syncViewportHeight);
  }
  window.addEventListener("resize", syncViewportHeight);
  syncViewportHeight();
  // при фокусе на поле ввода — подскроллить к нему после того как клавиатура откроется
  $("#input").addEventListener("focus", () => {
    setTimeout(() => { $("#msgs").scrollTop = $("#msgs").scrollHeight; syncViewportHeight(); }, 300);
  });

  // ═══════════════ INIT ═══════════════
  applyPrefs();
  syncSend();

  const wsFirstOpen = new Promise((resolve) => {
    const check = () => { if (state.wsReady) resolve(); else setTimeout(check, 80); };
    check();
    setTimeout(resolve, 6000); // не блокируем страницу дольше 6с если WS не отвечает
  });
  async function initUser() {
    await authRefresh();
    await loadServerChats();
    await ensureActiveChat();
    renderChatList();
    await renderMessages();
    await loadFiles();
  }

  initUser().catch((e) => {
    console.error("initialization failed", e);
    acct.notice = "Не удалось загрузить аккаунт: " + e.message;
    ensureChat();
    renderChatList();
    renderMessagesFromLocal();
  }).finally(() => {
    connectWS();
    Promise.all([loadModels(), wsFirstOpen]).then(markPageReady).catch(markPageReady);
  });
})();
