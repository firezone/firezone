import { playwright } from "@vitest/browser-playwright";
import { defineConfig, mergeConfig } from "vitest/config";
import viteConfig from "./vite.config.ts";

export default mergeConfig(
  viteConfig,
  defineConfig({
    // The dev server pins port 1420 because Tauri expects it there; the screenshot
    // run has no such contract and must not fight `tauri dev` for the port.
    server: {
      strictPort: false,
    },

    test: {
      include: ["src-frontend/**/*.test.tsx"],
      browser: {
        enabled: true,
        headless: true,
        provider: playwright(),
        instances: [{ browser: "chromium" }],
      },
    },
  })
);
