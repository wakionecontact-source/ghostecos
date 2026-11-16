(async function () {
  "use strict";

  if (window.GhostAuthTelegramReady) await window.GhostAuthTelegramReady;

  const params = new URLSearchParams(location.search);
  // Пароль из адресной строки убираем сразу: такие ссылки оседают в логах и истории браузера.
  if (params.has("password") || params.has("username")) {
    params.delete("password");
    params.delete("username");
    const clean = params.toString();
    history.replaceState(null, "", location.pathname + (clean ? "?" + clean : "") + location.hash);
  }
  const returnTarget = params.has("return")
    ? safeReturn(params.get("return"))
    : (sameOriginReferrer() || "/home");
  const telegramWebApp = window.Telegram && window.Telegram.WebApp;
  const telegramLinkRequested = params.get("tg_link") === "1";
  const ssoRequestId = params.get("sso_request") || "";
  let clientId = params.get("client_id") || (telegramLinkRequested ? "ghogem_bot" : "");
  let authClient = null;
  let ssoRequest = null;
  const clientFlow = Boolean(clientId || ssoRequestId || params.has("client_id") || params.has("sso_request"));
  // Нативный вход: ?native=<scheme>&app=<Name>. Не путать с clientFlow (SSO):
  // после обычного входа/регистрации показываем хендофф в приложение.
  // Универсально для любого приложения: регистрируешь схему в ОС и открываешь
  // /v2/auth?mode=login&native=<scheme>&app=<Name>.
  const nativeScheme = (() => { const v = params.get("native") || ""; return /^[a-z][a-z0-9_-]{1,31}$/.test(v) ? v : ""; })();
  const nativeApp = (() => { const v = String(params.get("app") || "").replace(/[<>&"']/g, "").trim(); return (v || "приложение").slice(0, 40); })();
  // Иконка приложения (?icon=): только https или тот же origin, как safeAvatarUrl.
  const nativeIcon = (() => {
    try {
      const raw = String(params.get("icon") || "");
      if (!raw) return "";
      const url = new URL(raw, location.origin);
      return url.protocol === "https:" || url.origin === location.origin ? url.href : "";
    } catch (_) { return ""; }
  })();
  const nativeMode = Boolean(nativeScheme);
  const telegramLinkFlow = telegramLinkRequested && !!(telegramWebApp && telegramWebApp.initData);
  let clientAccounts = [];
  let selectedClientAccount = null;
  let clientAuthorizationBusy = false;
  let reuseSessionPromise = null;
  let authFinishPromise = null;
  let authFlowCompleted = false;
  if (telegramWebApp) {
    try { telegramWebApp.ready(); telegramWebApp.expand(); } catch (_) {}
  }

  function safeReturn(raw) {
    try {
      const value = String(raw || "");
      if (!value.startsWith("/") || value.startsWith("//")) return "/home";
      const url = new URL(value, location.origin);
      if (url.origin !== location.origin || /^\/(?:v2\/auth|auth(?:\/v2)?|authv2|login|register)(?:\/|$)/i.test(url.pathname)) return "/home";
      return url.pathname + url.search + url.hash;
    } catch (_) { return "/home"; }
  }

  function sameOriginReferrer() {
    try {
      if (!document.referrer) return "";
      const referrer = new URL(document.referrer);
      if (referrer.origin !== location.origin) return "";
      return safeReturn(referrer.pathname + referrer.search + referrer.hash);
    } catch (_) { return ""; }
  }

  // Срок cookie обязан совпадать со сроком токена: иначе фронт «залогинен»,
  // а сервер уже отвечает 401.
  const SESSION_FALLBACK_SECONDS = 30 * 24 * 3600;

  function cookieSet(token, maxAgeSeconds) {
    const secure = location.protocol === "https:" ? "; Secure" : "";
    const maxAge = Math.floor(Number(maxAgeSeconds)) > 0
      ? Math.floor(Number(maxAgeSeconds))
      : SESSION_FALLBACK_SECONDS;
    document.cookie = "gs_token=" + encodeURIComponent(token) +
      "; Path=/; Max-Age=" + maxAge + "; SameSite=Lax" + secure;
  }

  function cookieClear() {
    const secure = location.protocol === "https:" ? "; Secure" : "";
    document.cookie = "gs_token=; Path=/; Max-Age=0; SameSite=Lax" + secure;
  }

  function saveOnboardingProducts() {
    const raw = params.get("products");
    if (raw === null) return;
    const allowed = new Set(["GhostChat", "GhostSocial", "GhostBank"]);
    const products = [...new Set(raw.split(",").filter((name) => allowed.has(name)))];
    if (!products.length) return;
    try { localStorage.setItem("gs_onboarding_products", JSON.stringify(products)); } catch (_) {}
  }

  function saveSession(data) {
    if (!data || !data.token) throw new Error("Сервер не вернул сессию");
    localStorage.setItem("gs_token", data.token);
    localStorage.setItem("gs_me", JSON.stringify(data));
    cookieSet(data.token, data.expires_in);
    saveOnboardingProducts();
    if (window.GhostIDAccounts) {
      window.GhostIDAccounts.add(data.token, data).catch(function () {});
      window.dispatchEvent(new Event("ghostid-accounts-changed"));
    }
  }

  function goBack() { location.replace(returnTarget); }

  function showSignedIn(data) {
    const state = document.querySelector("[data-signed-in]");
    if (!state) return;

    const displayName = String(data.display_name || "").trim();
    const username = String(data.username || "").trim().replace(/^@/, "");
    const accountName = displayName || (username ? "@" + username : "аккаунт");
    const label = displayName && username && displayName.toLocaleLowerCase() !== username.toLocaleLowerCase()
      ? displayName + " (@" + username + ")"
      : accountName;
    const name = state.querySelector("[data-signed-in-name]");
    if (name) name.textContent = label;

    const returnLink = state.querySelector("[data-signed-in-return]");
    if (returnLink) returnLink.href = returnTarget;
    const tabs = document.querySelector(".tabs");
    if (tabs) tabs.hidden = true;
    for (const panel of document.querySelectorAll("[data-mode-panel]")) panel.hidden = true;
    state.hidden = false;
  }

  function showTelegramLinkStatus(message) {
    const status = document.getElementById("telegram-link-status");
    if (status) status.textContent = message;
  }

  function clearSiteSession() {
    try { localStorage.removeItem("gs_token"); localStorage.removeItem("gs_me"); } catch (_) {}
    try { cookieClear(); } catch (_) {}
  }

  // Хендофф в нативное приложение на существующих v2-компонентах:
  // выбор аккаунта + согласие + кнопка подтверждения, как в SSO-флоу.
  // Токен читается из localStorage этого же origin (его кладёт /v2/auth
  // после входа), возврат — на <scheme>://auth?token=….
  function showNativeHandoff(profile) {
    if (!nativeMode) return false;
    const token = globalSessionToken();
    if (!token) return false;
    const section = document.querySelector("[data-native-handoff]");
    if (!section) return false;
    const tabs = document.querySelector(".tabs");
    if (tabs) tabs.hidden = true;
    for (const panel of document.querySelectorAll("[data-mode-panel]")) panel.hidden = true;
    const signed = document.querySelector("[data-signed-in]");
    if (signed) signed.hidden = true;
    let username = "", display = "";
    try {
      const cached = JSON.parse(localStorage.getItem("gs_me") || "null") || {};
      username = String((profile && profile.username) || cached.username || "").replace(/^@/, "");
      display = String((profile && profile.display_name) || cached.display_name || "");
    } catch (_) {}
    const name = section.querySelector("[data-native-name]");
    if (name) name.textContent = display || (username ? "@" + username : "GhostEcos");
    const handle = section.querySelector("[data-native-handle]");
    if (handle) handle.textContent = username ? "@" + username : "";
    const avatar = section.querySelector("[data-native-avatar]");
    if (avatar) {
      const initial = String(display || username || "G").trim().charAt(0).toUpperCase() || "G";
      avatar.textContent = initial;
      // Подтягиваем реальную аватарку, как в SSO-флоу (в gs_me её может не быть).
      fetch("/api/soc/me", {
        cache: "no-store",
        headers: { Accept: "application/json", Authorization: "Bearer " + token },
      })
        .then((response) => (response.ok ? response.json() : null))
        .then((me) => {
          const url = me ? safeAvatarUrl(me.avatar_url) : "";
          if (!url) return;
          try {
            const cached = JSON.parse(localStorage.getItem("gs_me") || "null") || {};
            localStorage.setItem("gs_me", JSON.stringify({ ...cached, avatar_url: me.avatar_url }));
          } catch (_) {}
          const img = document.createElement("img");
          img.src = url;
          img.alt = "";
          img.onerror = () => img.remove();
          avatar.append(img);
        })
        .catch(() => {});
    }
    const dest = section.querySelector("[data-native-dest]");
    if (dest) dest.textContent = "Доступ получит «" + nativeApp + "». Продолжить под этим аккаунтом?";
    const service = section.querySelector("[data-native-service]");
    if (service) service.textContent = nativeApp;
    const logo = section.querySelector("[data-native-logo]");
    if (logo) logo.textContent = nativeApp.trim().charAt(0).toUpperCase() || "G";
    const logoImg = section.querySelector("[data-native-logoimg]");
    if (logoImg && nativeIcon) {
      logoImg.onload = () => { logoImg.hidden = false; if (logo) logo.hidden = true; };
      logoImg.onerror = () => { logoImg.hidden = true; if (logo) logo.hidden = false; };
      logoImg.src = nativeIcon;
      logoImg.alt = "";
    }
    const deep = nativeScheme + "://auth?token=" + encodeURIComponent(token) +
      (username ? "&username=" + encodeURIComponent(username) : "");
    const consent = section.querySelector("[data-native-consent]");
    const cont = section.querySelector("[data-native-continue]");
    const status = section.querySelector("[data-native-status]");
    if (cont && !cont.dataset.bound) {
      cont.dataset.bound = "1";
      cont.addEventListener("click", () => {
        if (!section.querySelector("[data-native-consent]")?.checked) {
          if (status) status.textContent = "Подтверди согласие, чтобы продолжить.";
          return;
        }
        try { location.href = deep; } catch (_) {}
      });
    }
    if (consent && !consent.dataset.bound) {
      consent.dataset.bound = "1";
      consent.addEventListener("change", () => {
        if (status) status.textContent = "";
        if (cont) cont.disabled = !consent.checked;
      });
    }
    if (consent) { consent.checked = false; }
    if (cont) { cont.disabled = true; cont.textContent = "Подтвердить и открыть " + nativeApp; }
    if (status) status.textContent = "";
    const sw = section.querySelector("[data-native-switch]");
    if (sw && !sw.dataset.bound) {
      sw.dataset.bound = "1";
      sw.addEventListener("click", (event) => { event.preventDefault(); clearSiteSession(); location.reload(); });
    }
    section.hidden = false;
    return true;
  }

  function globalSessionToken() {
    let token = "";
    try { token = localStorage.getItem("gs_token") || ""; } catch (_) {}
    if (!token) {
      try {
        const cached = JSON.parse(localStorage.getItem("gs_me") || "null");
        token = cached && typeof cached.token === "string" ? cached.token : "";
      } catch (_) {}
    }
    token = String(token || "").trim().replace(/^Bearer\s+/i, "");
    if (token && !token.startsWith("guest_")) return token;
    try {
      const match = document.cookie.match(/(?:^|;\s*)gs_token=([^;]*)/);
      const cookieToken = match ? decodeURIComponent(match[1]) : "";
      return cookieToken && !cookieToken.startsWith("guest_") ? cookieToken : "";
    } catch (_) { return ""; }
  }

  function safeAvatarUrl(raw) {
    if (!raw) return "";
    try {
      const url = new URL(String(raw), location.origin);
      return url.protocol === "https:" || url.origin === location.origin ? url.href : "";
    } catch (_) { return ""; }
  }

  async function loadClientInfo() {
    if (!clientFlow) return;
    if (params.has("sso_request") && !ssoRequestId.trim()) throw new Error("Не указан параметр sso_request (запрос входа)");
    if (!ssoRequestId && !clientId.trim()) throw new Error("Не указан параметр client_id (идентификатор сервиса)");
    const endpoint = ssoRequestId
      ? "/api/sso/requests/" + encodeURIComponent(ssoRequestId)
      : "/api/sso/clients/" + encodeURIComponent(clientId);
    const load = () => fetch(endpoint, { credentials: "same-origin", cache: "no-store", headers: { Accept: "application/json" } });
    let response = await load();
    // Ссылка входа живёт 30 минут: просим продлить, чтобы человек не упирался в тупик.
    if (response.status === 410 && ssoRequestId) {
      const renewed = await fetch("/api/v2/auth/requests/" + encodeURIComponent(ssoRequestId) + "/renew", {
        method: "POST", credentials: "same-origin", cache: "no-store", headers: { Accept: "application/json" },
      }).catch(() => null);
      if (renewed && renewed.ok) response = await load();
    }
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(errorText(data, "Не удалось загрузить запрос входа"));
    const client = data.client;
    if (!client || typeof client !== "object") throw new Error("В ответе GhostID не указано поле client (настройки сервиса)");
    const required = ["clientId", "name", "transport", "websiteUrl", "termsUrl", "privacyUrl", "termsVersion", "privacyVersion"];
    const missing = required.filter((field) => client[field] == null || typeof client[field] === "string" && !client[field].trim());
    for (const field of ["scopes", "permissions"]) {
      if (client[field] == null || Array.isArray(client[field]) && !client[field].length) missing.push(field);
    }
    if (missing.length) throw new Error("В настройках сервиса не указаны поля: " + missing.join(", "));
    const invalid = required.filter((field) => typeof client[field] !== "string");
    for (const field of ["scopes", "permissions"]) {
      if (!Array.isArray(client[field]) || client[field].some((value) => typeof value !== "string" || !value.trim())) invalid.push(field);
    }
    if (invalid.length) throw new Error("В настройках сервиса некорректные поля: " + invalid.join(", "));
    if (ssoRequestId) {
      const missingRequest = ["request_id", "redirect_uri", "prompt", "expires_at"].filter((field) => data[field] == null || data[field] === "");
      if (missingRequest.length) throw new Error("В запросе входа не указаны поля: " + missingRequest.join(", "));
    }
    authClient = client;
    clientId = authClient.clientId;
    if (ssoRequestId) ssoRequest = data;
  }

  function updateClientContinue() {
    const button = document.getElementById("client-continue");
    const consent = document.getElementById("client-consent");
    if (!button || !consent) return;
    button.disabled = !selectedClientAccount || !selectedClientAccount.verified || !consent.checked || clientAuthorizationBusy;
    button.textContent = clientAuthorizationBusy ? "Подтверждаю вход…" : "Подтвердить и дать доступ";
  }

  // Догружает аватарку, если в профиле её нет (ответы /login и /register
  // avatar_url не содержат). Обновляет строку и экран согласия + кэш gs_me.
  async function enrichAccountAvatar(account) {
    if (!account || (account.profile && account.profile.avatar_url) || !account.token) return;
    try {
      const response = await fetch("/api/soc/me", {
        cache: "no-store",
        headers: { Accept: "application/json", Authorization: "Bearer " + account.token },
      });
      if (!response.ok) return;
      const me = await response.json().catch(() => null);
      if (!me || !me.avatar_url) return;
      account.profile = { ...(account.profile || {}), avatar_url: me.avatar_url };
      try {
        const cached = JSON.parse(localStorage.getItem("gs_me") || "null") || {};
        localStorage.setItem("gs_me", JSON.stringify({ ...cached, avatar_url: me.avatar_url }));
      } catch (_) {}
      renderClientAccounts();
      renderClientConsentAccount();
    } catch (_) {}
  }

  function renderClientConsentAccount() {
    const container = document.getElementById("client-consent-account");
    if (!container || !selectedClientAccount) return;
    container.replaceChildren();
    container.setAttribute("role", "group");
    container.setAttribute("aria-label", "Выбранный аккаунт GhostEcos");
    const profile = selectedClientAccount.profile || {};
    const avatar = document.createElement("span");
    avatar.className = "account-avatar";
    avatar.textContent = String(profile.display_name || profile.username || "G").trim().charAt(0).toUpperCase() || "G";
    const avatarUrl = safeAvatarUrl(profile.avatar_url);
    if (avatarUrl) {
      const image = document.createElement("img");
      image.src = avatarUrl;
      image.alt = "";
      image.onerror = () => image.remove();
      avatar.append(image);
    }
    const copy = document.createElement("span");
    copy.className = "consent-account-copy";
    const display = document.createElement("strong");
    display.textContent = profile.display_name || profile.username || "GhostEcos";
    const handle = document.createElement("small");
    handle.textContent = profile.username
      ? "@" + String(profile.username).replace(/^@/, "")
      : "GhostEcos ID " + selectedClientAccount.id;
    copy.append(display, handle);
    container.append(avatar, copy);
  }

  function renderClientAccounts() {
    const list = document.getElementById("client-account-list");
    if (!list) return;
    list.replaceChildren();
    for (const account of clientAccounts) {
      const profile = account.profile || {};
      const row = document.createElement("button");
      row.type = "button";
      row.className = "account-choice";
      row.setAttribute("role", "listitem");
      row.setAttribute("aria-pressed", String(account === selectedClientAccount));
      row.disabled = !account.verified;
      row.setAttribute("aria-disabled", String(!account.verified));
      if (!account.verified) row.title = "Проверяю сессию GhostEcos…";

      const avatar = document.createElement("span");
      avatar.className = "account-avatar";
      const initial = String(profile.display_name || profile.username || "G").trim().charAt(0).toUpperCase() || "G";
      avatar.textContent = initial;
      const avatarUrl = safeAvatarUrl(profile.avatar_url);
      if (avatarUrl) {
        const image = document.createElement("img");
        image.src = avatarUrl;
        image.alt = "";
        image.onerror = () => image.remove();
        avatar.append(image);
      }

      const copy = document.createElement("span");
      copy.className = "account-copy";
      const display = document.createElement("strong");
      display.textContent = profile.display_name || profile.username || "GhostEcos";
      const handle = document.createElement("small");
      handle.textContent = profile.username ? "@" + String(profile.username).replace(/^@/, "") : "GhostEcos ID " + account.id;
      copy.append(display, handle);

      const mark = document.createElement("span");
      mark.className = "account-selected-mark";
      mark.setAttribute("aria-hidden", "true");
      mark.innerHTML = '<svg viewBox="0 0 24 24"><path d="m5 12 4.5 4.5L19 7"/></svg>';
      row.append(avatar, copy, mark);
      row.addEventListener("click", () => {
        if (!account.verified) return;
        selectedClientAccount = account;
        const consent = document.getElementById("client-consent");
        if (consent) consent.checked = false;
        const status = document.getElementById("client-account-status");
        if (status) status.textContent = "";
        renderClientAccounts();
        renderClientConsentAccount();
        showClientConsent();
      });
      list.append(row);
    }
    updateClientContinue();
  }

  function animateClientLabelTransition() {
    const panel = document.querySelector(".client-auth-flow .auth-panel");
    if (!panel) return;
    panel.classList.remove("client-label-transition");
    void panel.offsetWidth;
    panel.classList.add("client-label-transition");
  }

  function showClientConsent() {
    if (!selectedClientAccount || !selectedClientAccount.verified) return;
    const accountStep = document.getElementById("client-account-step");
    const consentStep = document.getElementById("client-consent-step");
    const picker = document.getElementById("client-account-picker");
    const switchingFromAccounts = Boolean(accountStep && !accountStep.hidden);
    if (accountStep) accountStep.hidden = true;
    if (consentStep) consentStep.hidden = false;
    if (picker) picker.setAttribute("aria-labelledby", "client-consent-heading");
    renderClientConsentAccount();
    updateClientContinue();
    if (switchingFromAccounts) animateClientLabelTransition();
  }

  function addClientAccount(profile, token, verified = false) {
    if (!profile || profile.is_guest) return null;
    const id = String(profile.id ?? profile.user_id ?? profile.uid ?? profile.username ?? "");
    if (!id) return null;
    let account = clientAccounts.find((item) => item.id === id);
    if (!account) {
      account = { id, profile: {}, token: "", verified: false };
      clientAccounts.push(account);
    }
    account.profile = { ...account.profile, ...profile };
    if (token) account.token = token;
    if (verified) account.verified = true;
    const selectionStatus = document.getElementById("client-account-selection-status");
    if (selectionStatus) {
      selectionStatus.textContent = clientAccounts.some((item) => !item.verified)
        ? "Проверяю сессию GhostEcos…"
        : "";
    }
    const consent = document.getElementById("client-consent");
    if (consent) consent.checked = false;
    renderClientAccounts();
    return account;
  }

  function showClientChooser() {
    if (!authClient) return;
    const picker = document.getElementById("client-account-picker");
    const tabs = document.querySelector(".tabs");
    const scope = document.getElementById("client-scope-note");
    const back = document.getElementById("client-back-to-accounts");
    const accountStep = document.getElementById("client-account-step");
    const consentStep = document.getElementById("client-consent-step");
    const switchingFromConsent = Boolean(consentStep && !consentStep.hidden);
    if (picker) picker.hidden = false;
    if (picker) picker.setAttribute("aria-labelledby", "client-account-heading");
    if (accountStep) accountStep.hidden = false;
    if (consentStep) consentStep.hidden = true;
    if (tabs) tabs.hidden = true;
    for (const panel of document.querySelectorAll("[data-mode-panel]")) panel.hidden = true;
    const status = document.getElementById("telegram-link-status");
    if (status) status.hidden = true;
    if (scope) scope.hidden = true;
    if (back) back.hidden = true;
    renderClientAccounts();
    if (switchingFromConsent) animateClientLabelTransition();
  }

  function showClientLogin() {
    const picker = document.getElementById("client-account-picker");
    const tabs = document.querySelector(".tabs");
    const scope = document.getElementById("client-scope-note");
    const back = document.getElementById("client-back-to-accounts");
    selectedClientAccount = null;
    const consent = document.getElementById("client-consent");
    if (consent) consent.checked = false;
    if (picker) picker.hidden = true;
    if (tabs) tabs.hidden = false;
    if (scope && authClient) {
      scope.textContent = "Этот аккаунт будет выбран только для сервиса «" + authClient.name + "». Общая сессия GhostEcos не изменится.";
      scope.hidden = false;
    }
    if (back) back.hidden = clientAccounts.length === 0;
    document.getElementById("tab-login")?.click();
  }

  function configureClientPage() {
    if (!clientFlow) return;
    document.documentElement.classList.add("client-auth-flow");
    document.body.classList.add("client-auth-flow");
    const status = document.getElementById("telegram-link-status");
    if (!authClient) {
      if (status) status.textContent = "Этот сервис пока не подключён к единому входу GhostEcos.";
      document.querySelector(".tabs")?.setAttribute("hidden", "");
      for (const panel of document.querySelectorAll("[data-mode-panel]")) panel.hidden = true;
      return;
    }
    const title = document.getElementById("client-service-title");
    const serviceContext = document.getElementById("client-service-context");
    const serviceOrigin = document.getElementById("client-service-origin");
    const fallback = document.getElementById("client-service-fallback");
    const destination = document.getElementById("client-account-destination");
    const consentDestination = document.getElementById("client-consent-destination");
    const permissions = document.getElementById("client-permissions");
    const logo = document.getElementById("client-service-logo");
    const heroTitle = document.getElementById("hero-title");
    const heroCopy = document.getElementById("hero-copy");
    if (title) title.textContent = "Вход в " + authClient.name;
    if (serviceContext) {
      serviceContext.dataset.serviceName = authClient.name;
      serviceContext.hidden = false;
    }
    const serviceUrl = ssoRequest?.redirect_uri || authClient.websiteUrl;
    const serviceHost = serviceUrl ? new URL(serviceUrl).hostname : "";
    const serviceNote = authClient.trusted ? "" : "Внешний сервис · " + serviceHost;
    if (serviceOrigin) {
      serviceOrigin.textContent = serviceNote;
      serviceOrigin.hidden = !serviceNote;
    }
    if (destination) destination.textContent = serviceNote || "Продолжить в «" + (authClient.destination || authClient.name) + "».";
    if (consentDestination) consentDestination.textContent = serviceNote || "Проверь данные для входа в «" + authClient.name + "».";
    if (permissions) {
      permissions.replaceChildren();
      const details = Array.isArray(authClient.scopesDetail) ? authClient.scopesDetail : [];
      if (details.length) {
        for (const detail of details) {
          permissions.append(permissionItem(detail));
        }
      } else {
        for (const description of (Array.isArray(authClient.permissions) ? authClient.permissions : [])) {
          if (typeof description !== "string" || !description.trim()) continue;
          const item = document.createElement("li");
          item.textContent = description;
          permissions.append(item);
        }
      }
    }
    const gdaiService = String(authClient.clientId || "").trim().toLowerCase() === "gdai";
    if (logo) {
      logo.hidden = true;
      logo.classList.toggle("service-logo--gdai", gdaiService);
    }
    if (fallback) fallback.hidden = false;
    const serviceIcon = gdaiService ? "/auth/gdai-avatar.jpg" : safeAvatarUrl(authClient.icon);
    if (logo && serviceIcon) {
      logo.onload = () => { logo.hidden = false; if (fallback) fallback.hidden = true; };
      logo.onerror = () => { logo.hidden = true; if (fallback) fallback.hidden = false; };
      logo.src = serviceIcon;
      logo.alt = "";
    }
    if (heroTitle) heroTitle.textContent = "Вход в сервис";
    if (heroCopy) heroCopy.textContent = "Один аккаунт GhostEcos для разных приложений.";
    document.title = "Вход в " + authClient.name + " · GhostEcos";
    const terms = document.querySelector("#client-consent")?.closest("label");
    if (terms) {
      const links = terms.querySelectorAll("a");
      if (links[0] && authClient.termsUrl) links[0].href = authClient.termsUrl;
      if (links[1] && authClient.privacyUrl) links[1].href = authClient.privacyUrl;
    }
    const statusPanel = document.getElementById("client-account-status");
    if (statusPanel) statusPanel.textContent = "";
    const scope = document.getElementById("client-scope-note");
    if (scope) {
      scope.textContent = "Войди в GhostEcos, чтобы продолжить в " + authClient.name + ".";
      scope.hidden = false;
    }
  }

  /** Пункт анкеты: обязательные данные залочены, остальные снимаются галочкой. */
  function permissionItem(detail) {
    const item = document.createElement("li");
    item.className = "permission-item";
    const label = document.createElement("label");
    const box = document.createElement("input");
    box.type = "checkbox";
    box.checked = true;
    box.disabled = Boolean(detail.required);
    box.dataset.scope = String(detail.id || "");
    const text = document.createElement("span");
    const title = document.createElement("strong");
    title.textContent = String(detail.title || detail.id || "");
    const hint = document.createElement("small");
    hint.textContent = String(detail.description || "");
    text.append(title, hint);
    label.append(box, text);
    item.append(label);
    return item;
  }

  /** Выданный набор данных из анкеты; пустой список не отправляем. */
  function grantedScopes() {
    const boxes = document.querySelectorAll("#client-permissions input[data-scope]");
    if (!boxes.length) return null;
    const scopes = [];
    for (const box of boxes) {
      if (box.checked && box.dataset.scope) scopes.push(box.dataset.scope);
    }
    return scopes;
  }

  /** Подтверждение входа: отправляет согласие и уводит на callback сервиса. */
  async function authorizeClient({ automatic = false } = {}) {
    const status = document.getElementById("client-account-status");
    const button = document.getElementById("client-continue");
    if (!authClient || !button) return;
    if (!selectedClientAccount || !selectedClientAccount.verified) {
      if (status) status.textContent = "Аккаунт не подтверждён — войдите заново.";
      return;
    }
    if (!automatic && !document.getElementById("client-consent")?.checked) {
      if (status) status.textContent = "Отметьте согласие с условиями внизу анкеты.";
      return;
    }
    if (automatic && (!ssoRequest || ssoRequest.prompt !== "auto" || !authClient.trusted)) return;
    const endpoint = ssoRequest
      ? "/api/sso/requests/" + encodeURIComponent(ssoRequestId) + "/approve"
      : String(authClient.authorizationEndpoint || "");
    let endpointUrl;
    try { endpointUrl = new URL(endpoint, location.origin); } catch (_) {}
    if (!endpointUrl || endpointUrl.origin !== location.origin || !endpoint.startsWith("/")) {
      if (status) status.textContent = "У сервиса неверно настроен адрес входа.";
      return;
    }
    clientAuthorizationBusy = true;
    button.textContent = "Подтверждаю вход…";
    updateClientContinue();
    if (status) status.textContent = "";
    try {
      const headers = {
        "Accept": "application/json",
        "Content-Type": "application/json"
      };
      if (selectedClientAccount.token) {
        headers["X-Gs-Token"] = selectedClientAccount.token;
      }
      if (authClient.transport === "telegram-start" && telegramWebApp?.initData) {
        headers["X-Tg-Init-Data"] = telegramWebApp.initData;
      }
      const response = await fetch(endpointUrl.href, {
        method: "POST",
        credentials: "same-origin",
        headers,
        body: JSON.stringify(ssoRequest ? { consent: true, ...(automatic ? { automatic: true } : {}), ...(grantedScopes() ? { scopes: grantedScopes() } : {}) } : {
          client_id: authClient.clientId,
          consent: true,
          terms_version: authClient.termsVersion || "current",
          privacy_version: authClient.privacyVersion || "current"
        })
      });
      const data = await response.json().catch(() => ({}));
      if (automatic && response.status === 409 && data.code === "consent_required") {
        clientAuthorizationBusy = false;
        if (status) status.textContent = "Подтверди доступ один раз, чтобы дальше входить автоматически.";
        updateClientContinue();
        return;
      }
      if (!response.ok) throw new Error(errorText(data, "Не удалось подтвердить вход"));
      const redirectUrl = new URL(String(data.redirect_url || ""), location.origin);
      const allowedOrigins = Array.isArray(authClient.redirectOrigins) ? authClient.redirectOrigins : [];
      if (!allowedOrigins.includes(redirectUrl.origin) || redirectUrl.protocol !== "https:") {
        throw new Error("Сервис вернул небезопасную ссылку перехода.");
      }

      // Persist the explicitly selected first-party GhostSocial account on this device.
      // External SSO clients continue to receive only their scoped authorization code.
      if (authClient.clientId === 'ghostsocial' && authClient.trusted && redirectUrl.origin === location.origin) {
        if (selectedClientAccount.token) {
          saveSession({ ...selectedClientAccount.profile, token: selectedClientAccount.token });
        } else {
          const stored = localStorage.getItem('gs_token') || '';
          if (stored.startsWith('guest_')) localStorage.removeItem('gs_token');
          localStorage.setItem('gs_me', JSON.stringify(selectedClientAccount.profile));
        }
      }

      // The Telegram WebApp SDK object can exist in an ordinary browser too.
      // Use its bridge only when signed Mini App initData proves we are in Telegram.
      if (authClient.transport === "telegram-start" && telegramWebApp?.initData
          && typeof telegramWebApp.openTelegramLink === "function") {
        try { telegramWebApp.HapticFeedback?.notificationOccurred?.("success"); } catch (_) {}
        telegramWebApp.openTelegramLink(redirectUrl.href);
        setTimeout(() => { try { telegramWebApp.close?.(); } catch (_) {} }, 700);
      } else {
        // Firefox/desktop browser: follow the t.me deep link as a normal URL
        // so the browser can hand it to the installed Telegram app.
        location.assign(redirectUrl.href);
      }
    } catch (error) {
      clientAuthorizationBusy = false;
      if (status) status.textContent = error.message || "Не удалось подтвердить вход";
      updateClientContinue();
    }
  }

  async function denyClient() {
    if (!ssoRequest || !selectedClientAccount?.verified || clientAuthorizationBusy) return;
    const status = document.getElementById("client-account-status");
    clientAuthorizationBusy = true;
    updateClientContinue();
    try {
      const headers = { "Content-Type": "application/json", "Accept": "application/json" };
      if (selectedClientAccount.token) headers["X-Gs-Token"] = selectedClientAccount.token;
      const response = await fetch("/api/sso/requests/" + encodeURIComponent(ssoRequestId) + "/approve", {
        method: "POST", credentials: "same-origin", headers, body: JSON.stringify({ consent: false })
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(errorText(data, "Не удалось отменить вход"));
      const redirect = new URL(data.redirect_url, location.origin);
      if (redirect.protocol !== "https:" || !authClient.redirectOrigins.includes(redirect.origin)) throw new Error("Некорректный адрес возврата");
      location.assign(redirect.href);
    } catch (error) {
      clientAuthorizationBusy = false;
      if (status) status.textContent = error.message || "Не удалось отменить вход";
      updateClientContinue();
    }
  }

  async function finishAuthFlow() {
    if (clientFlow) {
      if (authClient && clientAccounts.length) showClientChooser();
      return Boolean(authClient && clientAccounts.length);
    }
    if (!telegramLinkRequested) { goBack(); return true; }
    if (!telegramLinkFlow) {
      showTelegramLinkStatus("Открой эту страницу кнопкой входа в Telegram, чтобы связать аккаунт с ботом.");
      return false;
    }
    if (authFlowCompleted) return true;
    if (authFinishPromise) return authFinishPromise;

    authFinishPromise = (async () => {
      await Promise.resolve();
      let succeeded = false;
      try {
        const token = localStorage.getItem("gs_token") || "";
        if (!token) throw new Error("Сессия GhostEcos не найдена. Войди ещё раз.");
        const response = await fetch("/ghogem-api/auth/link/webapp", {
          method: "POST",
          credentials: "same-origin",
          headers: {
            "Accept": "application/json",
            "X-Gs-Token": token,
            "X-Tg-Init-Data": telegramWebApp.initData,
          },
        });
        const data = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(errorText(data, "Не удалось связать аккаунты"));

        const botUsername = String(data.bot_username || "").replace(/^@/, "");
        const startParameter = String(data.start_parameter || "");
        if (!/^[A-Za-z0-9_]{5,32}$/.test(botUsername)) {
          throw new Error("Сервер не вернул корректную ссылку на бота");
        }
        if (!/^ghlogin_[A-Za-z0-9_-]{32}$/.test(startParameter)) {
          throw new Error("Сервер не вернул одноразовый код входа");
        }

        authFlowCompleted = true;
        succeeded = true;
        const botLink = "https://t.me/" + botUsername + "?start=" + encodeURIComponent(startParameter);
        showTelegramLinkStatus(
          "Аккаунт подтверждён. Открываю бота для завершения входа…"
        );
        try { telegramWebApp.HapticFeedback?.notificationOccurred?.("success"); } catch (_) {}
        setTimeout(() => {
          try {
            if (typeof telegramWebApp.openTelegramLink === "function") {
              telegramWebApp.openTelegramLink(botLink);
              // В новых клиентах переход по Telegram-ссылке не закрывает Mini App.
              setTimeout(() => {
                try { telegramWebApp.close?.(); } catch (_) {}
              }, 700);
            } else {
              location.replace(botLink);
            }
          } catch (_) {
            location.replace(botLink);
          }
        }, 350);
        return true;
      } catch (error) {
        showTelegramLinkStatus("Вход выполнен, но привязка не завершилась: " + (error.message || "ошибка сервера"));
        return false;
      } finally {
        if (!succeeded) authFinishPromise = null;
      }
    })();
    return authFinishPromise;
  }

  function errorText(data, fallback) {
    if (!data) return fallback;
    if (typeof data.detail === "string") return data.detail;
    if (Array.isArray(data.errors)) return data.errors.map((x) => x.message || x.field || "Ошибка данных").join("; ");
    if (Array.isArray(data.detail)) return data.detail.map((x) => (x.loc?.slice(1).join(".") || "body") + ": " + (x.msg || x.detail || "Ошибка")).join("; ");
    return data.message || fallback;
  }

  async function post(path, body) {
    let response;
    try {
      response = await fetch(path, {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json", "Accept": "application/json" },
        body: JSON.stringify(body),
      });
    } catch (_) { throw new Error("Не удалось связаться с сервером"); }
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(errorText(data, "Запрос не выполнен"));
    return data;
  }

  function bindCommon() {
    const loginLink = document.querySelector("[data-login-link]");
    const registerLink = document.querySelector("[data-register-link]");
    const ref = params.get("ref");
    const linkParams = clientFlow ? new URLSearchParams(params) : new URLSearchParams({ return: returnTarget });
    if (clientFlow) {
      linkParams.set("mode", "login");
      if (loginLink) loginLink.href = "/v2/auth?" + linkParams.toString();
      linkParams.set("mode", "register");
      if (registerLink) registerLink.href = "/v2/auth?" + linkParams.toString();
    } else {
      if (loginLink) loginLink.href = "/login?" + linkParams.toString();
      if (ref) linkParams.set("ref", ref);
      if (registerLink) registerLink.href = "/register?" + linkParams.toString();
    }
    const back = document.querySelector("[data-back-link]");
    if (back) back.href = returnTarget;
    const continueButton = document.querySelector("[data-success-continue]");
      if (continueButton) continueButton.addEventListener("click", () => {
        if (clientFlow) { showClientChooser(); return; }
        if (nativeMode) { showNativeHandoff(); return; }
        finishAuthFlow();
      });
  }

  async function reuseSession() {
    if (ssoRequest?.prompt === "login") return;
    if (reuseSessionPromise) return reuseSessionPromise;
    reuseSessionPromise = (async () => {
      const cached = globalSessionToken();
      let cachedProfile = null;
      try { cachedProfile = JSON.parse(localStorage.getItem("gs_me") || "null"); } catch (_) {}

      // Show the known account immediately, but keep Continue disabled until the server confirms it.
      if (clientFlow && cachedProfile && !cachedProfile.is_guest) {
        if (addClientAccount(cachedProfile, cached, false)) showClientChooser();
      }
      const headers = { Accept: "application/json" };
      if (cached) {
        headers.Authorization = "Bearer " + cached;
        headers["X-Gs-Token"] = cached;
      }
      try {
        const response = await fetch("/api/soc/me", {
          credentials: "include",
          cache: "no-store",
          headers
        });
        if (!response.ok) {
          const error = new Error("Не удалось подтвердить GhostEcos-сессию");
          error.status = response.status;
          throw error;
        }
        const data = await response.json();
        if (!data || !(data.id || data.user_id) || data.is_guest) throw new Error("Аккаунт не найден");
        try { localStorage.setItem("gs_me", JSON.stringify(data)); } catch (_) {}
        // Сессия продлена сервером — продлеваем и cookie, чтобы сроки не разъезжались.
        const expiresAt = Number(data.session_expires_at || 0);
        if (cached && expiresAt > 0) {
          cookieSet(cached, expiresAt - Math.floor(Date.now() / 1000));
        }
        if (clientFlow) {
          const account = addClientAccount(data, cached, true);
          if (account) {
            clientAccounts = clientAccounts.filter((item) => item.verified);
            showClientChooser();
            let automatic = false;
            try { automatic = localStorage.getItem("ghostid-auto-login:" + authClient.clientId) === "1"; } catch (_) {}
            if (ssoRequest?.prompt === "auto" && authClient.trusted && automatic) {
              selectedClientAccount = account;
              showClientConsent();
              await authorizeClient({ automatic: true });
            }
          }
        } else if (nativeMode) showNativeHandoff(data);
        else { /* экран «Вы уже вошли» выключен: показываем список аккаунтов */ }
      } catch (error) {
        // Мёртвый токен нельзя оставлять в браузере: иначе интерфейс врёт про вход.
        if (error && (error.status === 401 || error.status === 403)) clearSiteSession();
        if (clientFlow && error && (error.status === 401 || error.status === 403)) {
          clientAccounts = clientAccounts.filter((item) => item.verified);
          selectedClientAccount = clientAccounts[0] || null;
          if (!selectedClientAccount) {
            showClientLogin();
            const loginStatus = document.querySelector("[data-auth-form=login] [data-status]");
            if (loginStatus) loginStatus.textContent = cached ? "Сессия истекла. Войди в GhostEcos ещё раз." : "";
          }
        } else if (clientFlow && clientAccounts.some((item) => !item.verified)) {
          const status = document.getElementById("client-account-selection-status");
          if (status) status.textContent = "Не удалось проверить сессию. Попробуй ещё раз или войди заново.";
          renderClientAccounts();
        }
      }
    })();
    return reuseSessionPromise;
  }

  function initLogin() {
    const form = document.querySelector("[data-auth-form=login]");
    if (!form) return;
    const username = form.querySelector("[name=username]");
    const password = form.querySelector("[name=password]");
    const submit = form.querySelector("[type=submit]");
    const status = form.querySelector("[data-status]");
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      status.textContent = "";
      submit.disabled = true;
      submit.textContent = "Проверяю…";
      try {
        const data = await post("/api/soc/login", { username: username.value.trim(), password: password.value });
        if (clientFlow) {
          const account = addClientAccount(data, data.token, true);
          if (!account) throw new Error("Сервер не вернул GhostEcos-аккаунт");
          showClientChooser();
          enrichAccountAvatar(account);
          return;
        }
        saveSession(data);
        if (nativeMode) { showNativeHandoff(data); submit.disabled = false; submit.textContent = "Войти в экосистему"; return; }
        const finished = await finishAuthFlow();
        if (!finished) {
          submit.disabled = false;
          submit.textContent = "Повторить привязку";
        }
      } catch (error) {
        status.textContent = error.message || "Не удалось войти";
        submit.disabled = false;
        submit.textContent = "Войти в экосистему";
      }
    });
    const guest = document.querySelector("[data-guest]");
    if (guest) guest.addEventListener("click", async () => {
      guest.disabled = true;
      guest.textContent = "Подключаю…";
      status.textContent = "";
      try { saveSession(await post("/api/soc/guest", {})); await finishAuthFlow(); }
      catch (error) { status.textContent = error.message || "Не удалось продолжить"; guest.disabled = false; guest.textContent = "Продолжить без аккаунта"; }
    });
    reuseSession();
  }

  function initRegister() {
    const form = document.querySelector("[data-auth-form=register]");
    if (!form) return;
    // Не показываем регистрацию уже авторизованному пользователю: это
    // предотвращает повторную регистрацию и цикл возврата в продукт.
    reuseSession();
    const submit = form.querySelector("[type=submit]");
    const status = form.querySelector("[data-status]");
    const success = document.querySelector("[data-success]");
    const formWrap = document.querySelector("[data-form-wrap]");
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      status.textContent = "";
      const data = new FormData(form);
      const password = String(data.get("password") || "");
      const confirm = String(data.get("password_confirm") || "");
      if (password !== confirm) { status.textContent = "Пароли не совпадают"; return; }
      if (!form.querySelector("[name=age_18_confirm]").checked) { status.textContent = "Подтвердите возраст и условия"; return; }
      submit.disabled = true;
      submit.textContent = "Создаю аккаунт…";
      const ref = params.get("ref") || localStorage.getItem("gs_ref") || null;
      try {
        const payload = {
          username: String(data.get("username") || "").trim(),
          display_name: String(data.get("display_name") || "").trim(),
          password,
          age_18_confirm: true,
        };
        if (ref) payload.ref = ref.replace(/^@/, "").trim().toLowerCase();
        const result = await post("/api/soc/register", payload);
        if (clientFlow) {
          const account = addClientAccount(result, result.token, true);
          if (!account) throw new Error("Сервер не вернул GhostEcos-аккаунт");
          enrichAccountAvatar(account);
        } else {
          saveSession(result);
        }
        if (ref) localStorage.removeItem("gs_ref");
        if (result.seed_phrase && success && formWrap) {
          formWrap.style.display = "none";
          success.classList.add("visible");
          const seed = success.querySelector("[data-seed]");
          if (seed) seed.textContent = result.seed_phrase;
        } else if (clientFlow) {
          showClientChooser();
        } else if (nativeMode) { showNativeHandoff(result); }
        else await finishAuthFlow();
      } catch (error) {
        status.textContent = error.message || "Не удалось зарегистрироваться";
        submit.disabled = false;
        submit.textContent = "Создать аккаунт";
      }
    });
  }

  function bindClientFlow() {
    configureClientPage();
    if (!clientFlow) return;
    const status = document.getElementById("telegram-link-status");
    if (!authClient) {
      if (status) status.textContent = "Этот сервис пока не подключён к единому входу GhostEcos.";
      return;
    }
    const useOther = document.getElementById("client-use-other");
    const back = document.getElementById("client-back-to-accounts");
    const consentBack = document.getElementById("client-consent-back");
    const consent = document.getElementById("client-consent");
    const proceed = document.getElementById("client-continue");
    useOther?.addEventListener("click", showClientLogin);
    back?.addEventListener("click", showClientChooser);
    consentBack?.addEventListener("click", () => {
      selectedClientAccount = null;
      if (consent) consent.checked = false;
      const statusPanel = document.getElementById("client-account-status");
      if (statusPanel) statusPanel.textContent = "";
      showClientChooser();
    });
    consent?.addEventListener("change", updateClientContinue);
    proceed?.addEventListener("click", authorizeClient);
    const deny = document.getElementById("client-deny");
    if (deny) {
      deny.hidden = !ssoRequest;
      deny.addEventListener("click", denyClient);
    }
    const guest = document.querySelector("[data-guest]");
    if (guest) guest.hidden = true;
    const scope = document.getElementById("client-scope-note");
    if (scope) {
      scope.textContent = "Войди в GhostEcos, чтобы продолжить в " + authClient.name + ".";
      scope.hidden = false;
    }
  }

  async function bootstrap() {
    bindCommon();
    try {
      await loadClientInfo();
      if (clientFlow && authClient.transport === "authorization-code" && !ssoRequest) {
        throw new Error("Не указан параметр sso_request (запрос входа). Открой вход кнопкой на сайте сервиса.");
      }
      bindClientFlow();
      initLogin();
      initRegister();
    } catch (error) {
      document.documentElement.classList.add("client-auth-flow");
      document.querySelector(".tabs")?.setAttribute("hidden", "");
      for (const panel of document.querySelectorAll("[data-mode-panel]")) panel.hidden = true;
      const status = document.getElementById("telegram-link-status");
      if (status) { status.hidden = false; status.textContent = error.message || "Не удалось подготовить вход"; }
    }
  }
  bootstrap();
})();
