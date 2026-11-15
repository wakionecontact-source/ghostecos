/* Public SSO client catalog. Add products here; auth.js renders the same chooser for every client. */
window.GhostEcosAuthClients = Object.freeze({
  ghogem_bot: Object.freeze({
    clientId: "ghogem_bot",
    name: "GhoGemo",
    destination: "Telegram-бот GhoGemo",
    icon: "/ghogem/ghogemava.jpg",
    authorizationEndpoint: "/ghogem-api/auth/link/webapp",
    transport: "telegram-start",
    redirectOrigins: ["https://t.me"],
    termsUrl: "/terms",
    privacyUrl: "/privacy",
    termsVersion: "2026-09-28",
    privacyVersion: "2026-09-28",
    scopes: ["ghostid:basic", "telegram:link"],
    permissions: [
      "ID и имя пользователя GhostEcos, чтобы определить выбранный аккаунт",
      "Telegram ID и публичное имя пользователя для привязки и входа в бота",
      "После привязки чаты и файлы GhoGemo будут общими между сайтом и ботом"
    ]
  })
});
