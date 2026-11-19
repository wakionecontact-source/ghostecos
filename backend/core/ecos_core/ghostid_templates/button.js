(() => {
  "use strict";
  const issuer = __GHOSTID_ISSUER__;
  for (const container of document.querySelectorAll("[data-ghostid-button]")) {
    if (container.dataset.ghostidReady) continue;
    container.dataset.ghostidReady = "true";
    const params = new URLSearchParams({ origin: location.origin });
    if (container.dataset.app) params.set("client_id", container.dataset.app);
    fetch(issuer + "/api/sso/apps/resolve?" + params, {
      credentials: "omit", cache: "no-store", redirect: "error", signal: AbortSignal.timeout(10000)
    }).then(async response => {
      if (!response.ok) throw new Error("Кнопка входа пока недоступна");
      const { app } = await response.json();
      const url = new URL(app.widget_url);
      if (url.origin !== issuer || !url.pathname.startsWith("/api/sso/widget/")) throw new Error();
      const frame = document.createElement("iframe");
      frame.src = url.href;
      frame.title = "Войти через GhostID";
      frame.referrerPolicy = "no-referrer";
      frame.style.cssText = "display:block;width:100%;max-width:360px;height:56px;border:0;color-scheme:normal";
      container.replaceChildren(frame);
    }).catch(() => {
      const notice = document.createElement("span");
      notice.textContent = "Вход через GhostID пока недоступен";
      notice.setAttribute("role", "status");
      container.replaceChildren(notice);
    });
  }
})();
