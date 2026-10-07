(() => {
  "use strict";
  const root = document.documentElement;
  const btn = document.getElementById("v2ThemeBtn");
  const meta = document.querySelector('meta[name="theme-color"]');
  const KEY = "ghogem:v2:theme";

  function apply(theme) {
    const value = theme === "dark" ? "dark" : "purple";
    root.dataset.v2Theme = value;
    try { localStorage.setItem(KEY, value); } catch (e) {}
    if (meta) meta.content = value === "dark" ? "#130d20" : "#351180";
    if (btn) {
      btn.setAttribute("aria-label", value === "dark" ? "Фиолетовая тема" : "Тёмная тема");
      btn.innerHTML = value === "dark"
        ? '<svg class="ic" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9 7 7M17 17l2.1 2.1M4.9 19.1 7 17M17 7l2.1-2.1"/></svg>'
        : '<svg class="ic" viewBox="0 0 24 24"><path d="M12 3a9 9 0 1 0 9 9 7 7 0 0 1-9-9Z"/></svg>';
    }
    const tg = window.Telegram && window.Telegram.WebApp;
    if (tg) {
      const color = value === "dark" ? "#130d20" : "#351180";
      try {
        tg.setHeaderColor && tg.setHeaderColor(color);
        tg.setBackgroundColor && tg.setBackgroundColor(color);
      } catch (e) {}
    }
  }

  let saved = "purple";
  try { saved = localStorage.getItem(KEY) || "purple"; } catch (e) {}
  apply(saved);
  if (btn) btn.addEventListener("click", () => apply(root.dataset.v2Theme === "dark" ? "purple" : "dark"));

  const interactive = 'button,a,[role="button"],.chat-row,.fcard,.mcard,.sug,.action-card,.ctx-product-row,.ctx-chat-row,.canvas-tab,.prov-tab,.user-chip,.media-file';
  document.addEventListener("pointerdown", (event) => {
    const target = event.target.closest(interactive);
    if (!target || target.hasAttribute("disabled")) return;
    target.classList.remove("v2-tap");
    void target.offsetWidth;
    target.classList.add("v2-tap");
    setTimeout(() => target.classList.remove("v2-tap"), 240);
  }, { passive: true });
})();