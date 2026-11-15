(async function () {
  "use strict";
  const button = document.getElementById("sign-in");
  const status = document.getElementById("status");
  button.addEventListener("click", async () => {
    button.disabled = true; status.textContent = "";
    try { await GhostID.begin("ghostchat"); }
    catch (error) { button.disabled = false; status.textContent = error.message || "Не удалось начать вход"; }
  });
  try {
    const result = await GhostID.finish();
    if (!result) return;
    const profile = result.identity;
    document.getElementById("intro").textContent = "Вход в GhostChat подтверждён.";
    document.getElementById("name").textContent = profile.name || profile.username;
    document.getElementById("username").textContent = "@" + profile.username;
    const avatar = document.getElementById("avatar");
    avatar.textContent = (profile.name || profile.username || "G").trim().charAt(0).toUpperCase();
    if (profile.picture) {
      const url = new URL(profile.picture, location.origin);
      if (url.protocol === "https:" || url.origin === location.origin) {
        const image = document.createElement("img"); image.src = url.href; image.alt = "";
        image.onerror = () => image.remove(); avatar.append(image);
      }
    }
    document.getElementById("account").hidden = false;
    button.textContent = "Выбрать другой аккаунт";
  } catch (error) { status.textContent = error.message || "Не удалось завершить вход"; }
})();
