/* Telegram is optional; a blocked SDK must never block the browser login. */
(function () {
  'use strict';
  var hash = new URLSearchParams(location.hash.replace(/^#/, ''));
  var query = new URLSearchParams(location.search);
  var insideTelegram = !!(window.Telegram && window.Telegram.WebApp) ||
    hash.has('tgWebAppData') || hash.has('tgWebAppPlatform') ||
    query.has('tgWebAppData') || query.has('tgWebAppPlatform');
  window.GhostAuthTelegramReady = new Promise(function (resolve) {
    if (!insideTelegram || (window.Telegram && window.Telegram.WebApp)) { resolve(); return; }
    var script = document.createElement('script');
    var timer;
    function finish() {
      clearTimeout(timer);
      script.onload = script.onerror = null;
      resolve();
    }
    script.async = true;
    script.src = 'https://telegram.org/js/telegram-web-app.js';
    script.onload = script.onerror = finish;
    timer = setTimeout(finish, 4000);
    document.head.appendChild(script);
  });
})();
