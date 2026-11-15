/* GhostID browser helper: the same integration code works for every registered client. */
(function (global) {
  "use strict";
  const DEFAULT_ISSUER = "https://ghostecos.duckdns.org";
  const CALLBACK_KEYS = ["code", "state", "iss", "error", "error_description"];
  const encode = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const random = () => encode(crypto.getRandomValues(new Uint8Array(32)));
  const textValue = (value) => typeof value === "string" && Boolean(value.trim());
  const positiveNumber = (value) => typeof value === "number" && Number.isFinite(value) && value > 0;
  function requireData(data, fields, context) {
    const missing = Object.keys(fields).filter((field) => data?.[field] == null ||
      typeof data[field] === "string" && !data[field].trim());
    if (missing.length) {
      throw Object.assign(new Error(context + ": не указаны поля " + missing.join(", ")),
        { code: "missing_fields", missingFields: missing });
    }
    const invalid = Object.keys(fields).filter((field) => !fields[field](data[field]));
    if (invalid.length) throw new Error(context + ": некорректные поля " + invalid.join(", "));
  }
  function issuerOf(options) {
    if (!options || typeof options !== "object" || Array.isArray(options)) throw new Error("Некорректные параметры входа (options): нужен объект");
    if (options.issuer !== undefined) requireData(options, { issuer: textValue }, "Настройки GhostID");
    const url = new URL(options.issuer || DEFAULT_ISSUER);
    if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash || (url.pathname !== "/" && url.pathname !== "")) {
      throw new Error("GhostID issuer must be an HTTPS origin");
    }
    return url.origin;
  }
  async function jsonRequest(url, options) {
    const response = await fetch(url, { ...options, credentials: "omit", cache: "no-store" });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      const detail = typeof result?.detail === "string" ? result.detail : Array.isArray(result?.detail)
        ? result.detail.map((item) => (item.loc?.slice(1).join(".") || "body") + ": " + (item.msg || "ошибка данных")).join("; ")
        : "Не удалось выполнить запрос GhostID";
      throw Object.assign(new Error(detail), { code: result?.code, missingFields: result?.missing_fields || [] });
    }
    return result;
  }
  function storageKey(issuer, state) { return "ghostid-flow:" + issuer + ":" + state; }
  function cleanCallback() {
    const url = new URL(location.href);
    for (const key of CALLBACK_KEYS) url.searchParams.delete(key);
    history.replaceState(history.state, "", url.pathname + url.search + url.hash);
  }
  async function createEntrance(clientId, options = {}) {
    requireData({ client_id: clientId }, { client_id: textValue }, "Запрос входа");
    const issuer = issuerOf(options);
    const verifier = encode(crypto.getRandomValues(new Uint8Array(48)));
    const challenge = encode(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
    const state = random();
    const redirectUri = options.redirectUri === undefined ? location.origin + location.pathname : options.redirectUri;
    requireData({ redirect_uri: redirectUri }, { redirect_uri: textValue }, "Запрос входа");
    const body = { client_id: clientId, redirect_uri: redirectUri, state, code_challenge: challenge,
      code_challenge_method: "S256", prompt: options.prompt === undefined ? "select_account" : options.prompt };
    if (options.scopes !== undefined) body.scopes = options.scopes;
    const request = await jsonRequest(issuer + "/api/sso/entrance", {
      method: "POST", headers: { "Content-Type": "application/json", "Accept": "application/json" }, body: JSON.stringify(body)
    });
    requireData(request, { authorization_url: textValue, request_id: textValue, state: textValue,
      redirect_uri: textValue, expires_in: positiveNumber }, "Ответ /api/sso/entrance");
    if (request.state !== state || request.redirect_uri !== redirectUri) throw new Error("Ответ GhostID не совпадает с запросом входа (state, redirect_uri)");
    const authorization = new URL(request.authorization_url);
    if (authorization.origin !== issuer || authorization.pathname !== "/v2/auth") throw new Error("Unexpected GhostID authorization URL");
    sessionStorage.setItem(storageKey(issuer, state), JSON.stringify({ issuer, state, clientId, redirectUri,
      verifier, expiresAt: Date.now() + request.expires_in * 1000 }));
    return { authorizationUrl: authorization.href, state, requestId: request.request_id };
  }
  async function begin(clientId, options = {}) {
    const request = await createEntrance(clientId, options);
    location.assign(request.authorizationUrl);
    return request;
  }
  async function finish(options = {}) {
    const params = new URLSearchParams(location.search);
    if (!["code", "error", "state", "iss"].some((key) => params.has(key))) return null;
    const callbackFields = { state: textValue, iss: textValue, [params.has("error") ? "error" : "code"]: textValue };
    requireData(Object.fromEntries(params), callbackFields, "Ответ GhostID");
    const issuer = issuerOf(options), state = params.get("state") || "";
    if (!/^[A-Za-z0-9_-]{43}$/.test(state)) throw new Error("Некорректное поле state в ответе GhostID");
    const key = storageKey(issuer, state), saved = sessionStorage.getItem(key);
    if (!saved) throw new Error("Запрос входа не найден. Начни вход ещё раз.");
    let flow;
    try { flow = JSON.parse(saved); } catch (_) { throw new Error("Некорректные сохранённые данные запроса входа"); }
    requireData(flow, { issuer: textValue, state: textValue, clientId: textValue,
      redirectUri: textValue, verifier: textValue, expiresAt: positiveNumber }, "Сохранённый запрос входа");
    if (flow.issuer !== issuer || params.get("iss") !== issuer || flow.state !== state || flow.expiresAt <= Date.now()) {
      sessionStorage.removeItem(key); cleanCallback();
      throw new Error("Запрос входа истёк или не совпадает с ответом GhostID.");
    }
    const callback = new URL(flow.redirectUri);
    if (callback.origin !== location.origin || callback.pathname !== location.pathname) throw new Error("Unexpected GhostID callback location");
    if (params.has("error")) {
      sessionStorage.removeItem(key); cleanCallback();
      throw new Error(params.get("error") === "access_denied" ? "Вход отменён" : "Не удалось завершить вход");
    }
    const code = params.get("code");
    cleanCallback();
    const grant = await jsonRequest(issuer + "/api/sso/token", { method: "POST",
      headers: { "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify({ grant_type: "authorization_code", client_id: flow.clientId, code,
        redirect_uri: flow.redirectUri, code_verifier: flow.verifier }) });
    sessionStorage.removeItem(key);
    requireData(grant, { access_token: textValue, token_type: textValue,
      expires_in: positiveNumber, scope: textValue }, "Ответ /api/sso/token");
    if (grant.token_type !== "Bearer") throw new Error("Некорректное поле token_type в ответе GhostID");
    const identity = await jsonRequest(issuer + "/api/sso/userinfo", {
      headers: { "Authorization": "Bearer " + grant.access_token, "Accept": "application/json" }
    });
    requireData(identity, { sub: textValue, username: textValue, client_id: textValue }, "Ответ /api/sso/userinfo");
    if (identity.client_id !== flow.clientId) throw new Error("Профиль GhostID не принадлежит этому сервису (client_id)");
    return { identity, accessToken: grant.access_token, expiresIn: grant.expires_in, clientId: flow.clientId, scope: grant.scope };
  }
  global.GhostID = Object.freeze({ createEntrance, begin, finish });
})(window);
