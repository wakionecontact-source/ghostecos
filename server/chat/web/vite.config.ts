import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

export default defineConfig({
  // nginx отдаёт клиент по /v2/chat и ассеты по /v2/chat/assets.
  base: '/v2/chat/',
  plugins: [svelte()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: 'https://ghostecos.duckdns.org',
        changeOrigin: true,
        ws: true,
      },
    },
  },
});
