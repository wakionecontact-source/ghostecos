(function () {
  "use strict";
  const auth = document.getElementById("authScreen");
  if (!auth) return;
  const target = location.pathname + location.search + location.hash;
  const query = "?return=" + encodeURIComponent(target);
  const login = auth.querySelector("[data-auth-login]");
  const register = auth.querySelector("[data-auth-register]");
  if (login) login.href = "/login" + query;
  if (register) register.href = "/register" + query;
  // V1 opens in the supported guest mode; app.js creates that session.
  if (location.pathname === "/v1/social" || document.body.classList.contains("ghostsocial-v2")) return;
  // Не проверяем только display authScreen: app.js показывает его на время
  // асинхронной проверки cookie, и такой ранний check создаёт цикл.
  const sessionToken = (function () {
    try {
      const stored = localStorage.getItem("gs_token") || "";
      const token = stored.trim().replace(/^Bearer\s+/i, "");
      if (token) return token;
    } catch (_) {}
    try {
      const match = document.cookie.match(/(?:^|;\s*)gs_token=([^;]*)/);
      return match ? decodeURIComponent(match[1]).trim().replace(/^Bearer\s+/i, "") : "";
    } catch (_) { return ""; }
  })();
  const headers = { "Accept": "application/json", "X-Ghost-Web": "1" };
  if (sessionToken) headers.Authorization = "Bearer " + sessionToken;
  fetch("/api/soc/me", {
    credentials: "include",
    cache: "no-store",
    headers: headers,
  }).then(function (response) {
    if (response.ok) return;
    if (response.status === 401 || response.status === 403) {
      location.replace("/login" + query);
    }
  }).catch(function () {
    // Сетевой сбой не превращаем в бесконечный редирект.
  });
})();
