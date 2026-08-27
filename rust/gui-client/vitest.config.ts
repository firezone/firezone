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

    // Vitest pre-bundles the dependency graph it discovers from the test file; React has to
    // ride along or the components end up talking to a second, hook-less copy of it.
    optimizeDeps: {
      include: ["react", "react/jsx-dev-runtime", "react-dom/client"],
    },

    // The About screen prints the version and the commit it was built from, which would
    // move its image on every push.
    define: {
      __APP_VERSION__: JSON.stringify("0.0.0"),
      __GIT_VERSION__: JSON.stringify(
        "0000000000000000000000000000000000000000"
      ),
    },

    test: {
      include: ["src-frontend/**/*.test.tsx"],
      browser: {
        enabled: true,
        headless: true,
        provider: playwright(),
        instances: [{ browser: "chromium" }],
        screenshotFailures: false,
      },
    },
  })
);
