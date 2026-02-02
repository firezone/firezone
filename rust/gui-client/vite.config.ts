import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig, Plugin } from "vite";
import flowbiteReact from "flowbite-react/plugin/vite";
import typescript from "vite-plugin-typescript";
import { execSync } from "child_process";
import { writeFileSync } from "fs";
import { join } from "path";

// Plugin to recreate .gitkeep after build (Vite's emptyOutDir deletes it)
function preserveGitkeep(): Plugin {
  return {
    name: "preserve-gitkeep",
    writeBundle(options) {
      const outDir = options.dir ?? "dist";
      writeFileSync(join(outDir, ".gitkeep"), "");
    },
  };
}

const host = process.env.TAURI_DEV_HOST;
const gitVersion =
  process.env.GITHUB_SHA ?? execSync("git rev-parse --short HEAD").toString();

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    react(),
    flowbiteReact(),
    tailwindcss(),
    typescript(),
    preserveGitkeep(),
  ],

  define: {
    // mark:next-gui-version
    __APP_VERSION__: JSON.stringify("1.5.11"),
    __GIT_VERSION__: JSON.stringify(gitVersion),
  },

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
});
