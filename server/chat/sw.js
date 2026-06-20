// GhostChat Service Worker — DEPRECATED.
// Если зарегистрирован у юзера — снимаем и зачищаем кеши.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', async (event) => {
  event.waitUntil((async () => {
    try {
      const keys = await caches.keys();
      await Promise.all(keys.map((k) => caches.delete(k)));
    } catch (_) {}
    try {
      const regs = await self.registration.unregister();
    } catch (_) {}
    try {
      const clients = await self.clients.matchAll();
      clients.forEach((c) => c.navigate(c.url));
    } catch (_) {}
  })());
});
self.addEventListener('fetch', (e) => { /* passthrough — не интерсептим */ });
