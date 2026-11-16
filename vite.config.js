import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { defineConfig } from 'vite'
import { metaCspFor } from './security.config.js'

// Adds the Content-Security-Policy to the built page. It's left out of the dev
// server, whose hot reload needs inline scripts and a websocket.
const securityMeta = () => ({
  name: 'security-meta',
  apply: 'build',
  transformIndexHtml: (html) =>
    html.replace(
      '<meta charset="UTF-8" />',
      `<meta charset="UTF-8" />\n    <meta http-equiv="Content-Security-Policy" content="${metaCspFor(process.env.VITE_SUPABASE_URL)}" />\n    <meta name="referrer" content="strict-origin-when-cross-origin" />`,
    ),
})

// BASE_PATH lets the same build target any host. The default "./" produces
// relative asset URLs, which work on Vercel, Netlify and GitHub Pages project
// sites alike because the app uses hash-based routing.
export default defineConfig({
  base: process.env.BASE_PATH || './',
  plugins: [react(), tailwindcss(), securityMeta()],
  build: {
    target: 'es2020',
    chunkSizeWarningLimit: 600,
    rollupOptions: {
      output: {
        // React, the router and the store library change only when a dependency is updated, so they get
        // a chunk of their own: after an ordinary deploy returning visitors re-download the site's own
        // code and keep this one cached. (The Supabase client stays in its own lazy chunk.)
        manualChunks: (id) => (/[\\/]node_modules[\\/](react|react-dom|scheduler|react-router|react-router-dom|zustand|cookie|set-cookie-parser)[\\/]/.test(id) ? 'vendor' : undefined),
      },
    },
  },
  test: {
    environment: 'node',
    include: ['src/**/*.test.js'],
  },
})
