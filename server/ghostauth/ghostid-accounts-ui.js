/* GhostID · сохранённые аккаунты как отдельный экран входа. */
(function () {
  "use strict";

  var box = document.querySelector("[data-ghostid-accounts]");
  if (!box) return;

  var list = box.querySelector("[data-gid-list]");
  var count = box.querySelector("[data-gid-count]");
  var hint = box.querySelector("[data-gid-hint]");
  var form = document.querySelector("[data-auth-form=login]");
  var tabs = document.querySelector(".tabs");
  var clientFlow = document.documentElement.classList.contains("client-auth-flow");
  var mode = "";

  function target() {
    var raw = "";
    try { raw = new URLSearchParams(location.search).get("return") || ""; } catch (_) {}
    if (!raw) return "/social";
    try {
      var url = new URL(raw, location.origin);
      if (url.origin !== location.origin) return "/social";
      return url.pathname + url.search + url.hash;
    } catch (_) { return "/social"; }
  }

  function avatarNode(profile) {
    var avatar = document.createElement("span");
    avatar.className = "ghostid-account-avatar";
    var raw = String(profile.avatar_url || "");
    var url = "";
    if (raw) {
      try {
        var parsed = new URL(raw, location.origin);
        if (parsed.protocol === "https:" || parsed.origin === location.origin) url = parsed.href;
      } catch (_) {}
    }
    if (url) {
      avatar.classList.add("has-image");
      avatar.style.backgroundImage = 'url("' + url.replace(/"/g, "%22") + '")';
      return avatar;
    }
    var name = String(profile.display_name || profile.username || "G").trim();
    avatar.textContent = name.charAt(0).toUpperCase() || "G";
    return avatar;
  }

  function panels() {
    return document.querySelectorAll("[data-mode-panel]");
  }

  function showAccounts() {
    if (clientFlow) return;
    if (mode === "accounts") return;
    mode = "accounts";
    if (tabs) tabs.hidden = true;
    panels().forEach(function (panel) { panel.hidden = true; });
    box.hidden = false;
  }

  function showForm() {
    if (mode === "form") return;
    mode = "form";
    box.hidden = true;
    if (tabs) tabs.hidden = false;
    var loginTab = document.getElementById("tab-login");
    if (loginTab) {
      loginTab.click();
    } else {
      panels().forEach(function (panel) {
        panel.hidden = panel.getAttribute("data-mode-panel") !== "login";
      });
    }
    var password = form && form.querySelector("[name=password]");
    if (password) password.value = "";
    var username = form && form.querySelector("[name=username]");
    if (username) {
      try { username.focus({ preventScroll: true }); } catch (_) { username.focus(); }
    }
  }

  function accountRow(entry, active) {
    var row = document.createElement("button");
    row.type = "button";
    row.className = "ghostid-account" + (active ? " is-current" : "");
    row.setAttribute("role", "listitem");

    var copy = document.createElement("span");
    copy.className = "ghostid-account-copy";
    var name = document.createElement("strong");
    name.textContent = entry.profile.display_name || ("@" + entry.profile.username);
    var handle = document.createElement("span");
    handle.className = "ghostid-account-handle";
    handle.textContent = "@" + entry.profile.username + (active ? " · текущий" : "");
    copy.append(name, handle);
    row.append(avatarNode(entry.profile), copy);

    if (!active) {
      row.addEventListener("click", function () {
        if (hint) hint.textContent = "";
        var picked = window.GhostIDAccounts.activate(entry.profile.id);
        if (!picked) {
          if (hint) hint.textContent = "Не удалось переключить аккаунт";
          return;
        }
        location.href = target();
      });
    }

    var drop = document.createElement("span");
    drop.className = "ghostid-account-drop";
    drop.setAttribute("role", "button");
    drop.setAttribute("tabindex", "0");
    drop.title = "Убрать из списка";
    drop.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">' + '<path d="M7 7l10 10M17 7L7 17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>';
    function forget(event) {
      event.preventDefault();
      event.stopPropagation();
      window.GhostIDAccounts.remove(entry.profile.id);
      render();
    }
    drop.addEventListener("click", forget);
    drop.addEventListener("keydown", function (event) {
      if (event.key === "Enter" || event.key === " ") forget(event);
    });
    row.append(drop);
    return row;
  }

  function addSeparator() {
    var line = document.createElement("div");
    line.className = "ghostid-accounts-sep";
    line.setAttribute("role", "separator");
    return line;
  }

  function addRow() {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "ghostid-account ghostid-account-add";
    button.innerHTML = '<span class="ghostid-account-avatar ghostid-account-plus" aria-hidden="true">' +
      '<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" focusable="false"><path fill="currentColor" d="M12 11.6a4.2 4.2 0 1 0 0-8.4 4.2 4.2 0 0 0 0 8.4Zm0 1.9c-4.1 0-7.5 2.3-7.5 5.1 0 .8.6 1.4 1.4 1.4h12.2c.8 0 1.4-.6 1.4-1.4 0-2.8-3.4-5.1-7.5-5.1Z"/></svg></span>' +
      '<span class="ghostid-account-copy"><strong>Добавить аккаунт</strong>' +
      '<span class="ghostid-account-handle">войти в другой аккаунт</span></span>';
    button.addEventListener("click", showForm);
    return button;
  }

  function render() {
    var store = window.GhostIDAccounts;
    if (!store) return;
    var items = store.list();
    var token = store.currentToken();
    list.replaceChildren();
    if (!items.length) {
      box.hidden = true;
      mode = "";
      return;
    }
    if (count) count.textContent = items.length + " из " + store.MAX;
    var marked = false;
    for (var i = 0; i < items.length; i++) {
      var isCurrent = !marked && Boolean(token) && items[i].token === token;
      if (isCurrent) marked = true;
      list.append(accountRow(items[i], isCurrent));
    }
    list.append(addSeparator(), addRow());
    showAccounts();
  }

  window.GhostIDAccountsUI = { refresh: render, showForm: showForm };
  render();

  var store = window.GhostIDAccounts;
  if (!store) return;
  document.addEventListener("ghostid-accounts-changed", render);
  if (store.list().length) store.sync().then(render).catch(render);
})();
