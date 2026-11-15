/* GhostID · сохранённые аккаунты.
   Общий стор для /login и продуктов экосистемы (GhostSocial и др.).
   Храним не больше 15 аккаунтов, в список попадают только сессии,
   которые сервер подтвердил через /api/soc/me. */
(function (global) {
  "use strict";

  var KEY = "gs_accounts_v1";
  var MAX = 15;
  var ME = "/api/soc/me";

  function read() {
    var raw;
    try { raw = JSON.parse(localStorage.getItem(KEY) || "[]"); } catch (_) { raw = []; }
    if (!Array.isArray(raw)) raw = [];
    var seen = Object.create(null);
    var list = [];
    for (var i = 0; i < raw.length && list.length < MAX; i++) {
      var item = raw[i];
      if (!item || typeof item !== "object") continue;
      var profile = item.profile;
      var token = typeof item.token === "string" ? item.token.trim() : "";
      if (!profile || !token) continue;
      var id = String(profile.id || "");
      if (!id || seen[id]) continue;
      seen[id] = true;
      list.push({
        token: token,
        savedAt: Number(item.savedAt) || 0,
        profile: {
          id: id,
          username: String(profile.username || "").replace(/^@/, ""),
          display_name: String(profile.display_name || ""),
          avatar_url: String(profile.avatar_url || ""),
          is_guest: Boolean(profile.is_guest)
        }
      });
    }
    return list;
  }

  function write(list) {
    var trimmed = list.slice(0, MAX);
    try { localStorage.setItem(KEY, JSON.stringify(trimmed)); } catch (_) {}
    return trimmed;
  }

  function profileOf(data) {
    if (!data || typeof data !== "object") return null;
    var id = data.id != null ? data.id : (data.user_id != null ? data.user_id : data.uid);
    if (id == null || String(id).trim() === "") return null;
    return {
      id: String(id),
      username: String(data.username || "").replace(/^@/, ""),
      display_name: String(data.display_name || ""),
      avatar_url: String(data.avatar_url || ""),
      is_guest: Boolean(data.is_guest)
    };
  }

  function cookieWrite(token) {
    var secure = location.protocol === "https:" ? "; Secure" : "";
    document.cookie = "gs_token=" + encodeURIComponent(token) +
      "; Path=/; Max-Age=31536000; SameSite=Lax" + secure;
  }

  function currentToken() {
    var token = "";
    try { token = localStorage.getItem("gs_token") || ""; } catch (_) {}
    if (!token) {
      try {
        var cached = JSON.parse(localStorage.getItem("gs_me") || "null");
        if (cached && typeof cached.token === "string") token = cached.token;
      } catch (_) {}
    }
    token = String(token || "").trim().replace(/^Bearer\s+/i, "");
    if (token && token.indexOf("guest_") !== 0) return token;
    try {
      var match = document.cookie.match(/(?:^|;\s*)gs_token=([^;]*)/);
      var cookieToken = match ? decodeURIComponent(match[1]).trim().replace(/^Bearer\s+/i, "") : "";
      return cookieToken && cookieToken.indexOf("guest_") !== 0 ? cookieToken : "";
    } catch (_) { return ""; }
  }

  async function verify(token) {
    var headers = { Accept: "application/json", "X-Ghost-Web": "1" };
    if (token) headers.Authorization = "Bearer " + token;
    var response;
    try {
      response = await fetch(ME, { credentials: "include", cache: "no-store", headers: headers });
    } catch (_) {
      return { ok: false, offline: true, data: null };
    }
    if (!response.ok) return { ok: false, status: response.status, data: null };
    var data = await response.json().catch(function () { return null; });
    var profile = profileOf(data);
    if (!profile || profile.is_guest) return { ok: false, status: 200, data: null };
    return { ok: true, status: 200, data: data, profile: profile };
  }

  async function add(token, data) {
    var clean = String(token || "").trim().replace(/^Bearer\s+/i, "");
    if (!clean || clean.indexOf("guest_") === 0) throw new Error("Нет сессии для сохранения");
    var result = data ? { ok: true, profile: profileOf(data) } : await verify(clean);
    if (!result.ok || !result.profile) throw new Error("Сессия не подтверждена сервером");
    var list = read();
    var index = -1;
    for (var i = 0; i < list.length; i++) {
      if (list[i].profile.id === result.profile.id) { index = i; break; }
    }
    if (index < 0 && list.length >= MAX) {
      throw new Error("Можно сохранить не больше " + MAX + " аккаунтов");
    }
    var entry = { token: clean, savedAt: Date.now(), profile: result.profile };
    if (index >= 0) list.splice(index, 1);
    list.unshift(entry);
    write(list);
    return entry;
  }

  function remove(id) {
    var key = String(id || "");
    return write(read().filter(function (item) { return item.profile.id !== key; }));
  }

  function activate(id) {
    var key = String(id || "");
    var list = read();
    var entry = null;
    for (var i = 0; i < list.length; i++) {
      if (list[i].profile.id === key) { entry = list[i]; break; }
    }
    if (!entry) return null;
    try {
      localStorage.setItem("gs_token", entry.token);
      localStorage.setItem("gs_me", JSON.stringify(Object.assign({ token: entry.token }, entry.profile)));
    } catch (_) {}
    cookieWrite(entry.token);
    var rest = list.filter(function (item) { return item.profile.id !== key; });
    rest.unshift(entry);
    write(rest);
    return entry;
  }

  async function sync() {
    var list = read();
    var checks = await Promise.all(list.map(function (entry) {
      return verify(entry.token).then(function (result) { return { entry: entry, result: result }; });
    }));
    var valid = [];
    for (var i = 0; i < checks.length; i++) {
      var item = checks[i];
      if (!item.result.ok && item.result.offline) {
        valid.push(item.entry);
        continue;
      }
      if (!item.result.ok) continue;
      item.entry.profile = Object.assign({}, item.entry.profile, item.result.profile);
      valid.push(item.entry);
    }
    var token = currentToken();
    if (token) {
      var own = await verify(token);
      if (own.ok) {
        var index = -1;
        for (var j = 0; j < valid.length; j++) {
          if (valid[j].profile.id === own.profile.id) { index = j; break; }
        }
        if (index >= 0) {
          valid[index].token = token;
          valid[index].profile = Object.assign({}, valid[index].profile, own.profile);
          var picked = valid.splice(index, 1)[0];
          valid.unshift(picked);
        } else if (valid.length < MAX) {
          valid.unshift({ token: token, savedAt: Date.now(), profile: own.profile });
        }
      }
    }
    return write(valid);
  }

  global.GhostIDAccounts = {
    MAX: MAX,
    KEY: KEY,
    list: read,
    add: add,
    remove: remove,
    activate: activate,
    verify: verify,
    sync: sync,
    currentToken: currentToken
  };
})(window);
