// Настройки выданы GhostStudio для этого приложения.
const config = Object.freeze(__GHOSTID_CONFIG__);
const cookieName = "__Host-GhostID-" + config.clientId;
const opaque = /^[A-Za-z0-9_-]{43}$/;
const paths = Object.fromEntries(Object.entries(config.urls).map(([key, url]) => [key, new URL(url).pathname]));

async function call(path, body) {
  const response = await fetch(config.issuer + "/api/sso/managed/" + path, {
    method: "POST", headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify(body), redirect: "error", signal: AbortSignal.timeout(10000)
  });
  const text = await response.text();
  if (text.length > 8192) throw new Error("Неверный ответ GhostID");
  const data = JSON.parse(text);
  if (!response.ok) throw new Error("Не удалось завершить вход. Начни его заново.");
  return data;
}

function nonceFromCookie(header = "") {
  const values = header.split(";").map(value => value.trim()).filter(value => value.startsWith(cookieName + "="));
  if (values.length !== 1) return "";
  return values[0].slice(cookieName.length + 1);
}

function cookie(res, value, age) {
  const previous = res.getHeader("Set-Cookie");
  const values = previous ? Array.isArray(previous) ? previous : [previous] : [];
  res.setHeader("Set-Cookie", [...values, cookieName + "=" + value +
    "; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=" + age]);
}

function fail(res, status, message) {
  if (res.headersSent) return;
  res.statusCode = status;
  res.setHeader("Content-Type", "text/plain; charset=utf-8");
  res.end(message);
}

export default function ghostID(onLogin) {
  return async function ghostIDReceiver(req, res, next) {
    const url = new URL(req.url, config.origin);
    if (!Object.values(paths).includes(url.pathname)) return next();
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("X-Content-Type-Options", "nosniff");
    if (req.method !== "GET") { res.setHeader("Allow", "GET"); return fail(res, 405, "Нужен запрос GET"); }
    try {
      if (url.pathname === paths.verify) {
        res.setHeader("Content-Type", "text/plain; charset=utf-8");
        return res.end(config.proof);
      }
      if (url.pathname === paths.start) {
        const data = await call("start", { client_id: config.clientId });
        const target = new URL(data.authorization_url);
        if (!opaque.test(data.nonce) || !opaque.test(data.state) ||
            target.origin !== config.issuer || target.pathname !== "/v2/auth") throw new Error();
        cookie(res, data.nonce, 600);
        res.statusCode = 303;
        res.setHeader("Location", target.href);
        return res.end();
      }
      const allowed = new Set(["code", "state", "iss", "error"]);
      const params = Object.fromEntries(url.searchParams);
      const nonce = nonceFromCookie(req.headers.cookie);
      if ([...url.searchParams].some(([key]) => !allowed.has(key) || url.searchParams.getAll(key).length !== 1) ||
          params.iss !== config.issuer || !opaque.test(params.state || "") || !opaque.test(nonce) ||
          (!!params.code === !!params.error) || (params.error && params.error !== "access_denied")) {
        return fail(res, 400, "Ответ входа не принадлежит этому браузеру. Начни вход заново.");
      }
      cookie(res, "", 0);
      const data = await call("complete", { client_id: config.clientId, state: params.state,
        nonce, iss: params.iss, ...(params.code ? { code: params.code } : { error: params.error }) });
      if (data.error === "access_denied") return fail(res, 403, "Ты отменил вход через GhostID.");
      if (data.client_id !== config.clientId || !data.user || typeof data.user.sub !== "string" || !data.user.sub) throw new Error();
      // Передаём в код сайта только подтверждённые открытые поля.
      const user = Object.fromEntries(["sub", "username", "name", "picture"]
        .filter(key => Object.hasOwn(data.user, key)).map(key => [key, data.user[key]]));
      req.ghostID = user;
      if (onLogin) return await onLogin(user, req, res);
      res.setHeader("Content-Type", "application/json; charset=utf-8");
      res.end(JSON.stringify(user));
    } catch {
      fail(res, 502, "Не удалось завершить вход через GhostID. Начни вход заново.");
    }
  };
}
