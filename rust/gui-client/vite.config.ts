import { defineConfig } from "vite";
import { resolve } from "path";
import tailwindcss from '@tailwindcss/vite'
import typescript from 'vite-plugin-typescript';

// @ts-expect-error process is a nodejs global
const host = process.env.TAURI_DEV_HOST;

// https://vitejs.dev/config/
export default defineConfig(async () => ({
  build: {
    rollupOptions: {
      input: {
        about: resolve(__dirname, "src/about.html"),
        settings: resolve(__dirname, "src/settings.html"),
        welcome: resolve(__dirname, "src/welcome.html"),
      },
    },
  },

  plugins: [
    tailwindcss(),
    typescript(),
  ],

  // Vite options tailored for Tauri development and only applied in `tauri dev` or `tauri build`
  //
  // 1. prevent vite from obscuring rust errors
  clearScreen: false,
  // 2. tauri expects a fixed port, fail if that port is not available
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 1421,
        }
      : undefined,
    watch: {
      // 3. tell vite to ignore watching `src-tauri`
      ignored: ["**/src-tauri/**"],
    },
  },
}));
