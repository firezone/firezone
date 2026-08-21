// Teaches `cdp()` the Playwright session shape; the provider augments `vitest/browser`.
import type {} from "@vitest/browser-playwright";
import { cdp, page } from "vitest/browser";
import React, { act } from "react";
import { createRoot, Root } from "react-dom/client";
import { afterEach, beforeEach, test } from "vitest";
import {
  AdvancedSettingsViewModel,
  GeneralSettingsViewModel,
  SessionViewModel,
} from "./generated/bindings";
import AboutPage from "./components/AboutPage";
import AdvancedSettingsPage from "./components/AdvancedSettingsPage";
import DiagnosticsPage from "./components/DiagnosticsPage";
import GeneralSettingsPage from "./components/GeneralSettingsPage";
import OverviewPage from "./components/OverviewPage";
import "./main.css";

// The window is 900x500 (see `tauri.conf.json`) and the shell spends 224px of that
// on the sidebar and 40px on the title bar, which the harness below leaves out.
const CONTENT_WIDTH = 676;
const CONTENT_HEIGHT = 460;

const COLOR_SCHEMES = ["light", "dark"] as const;

const noop = () => {};

const generalSettings: GeneralSettingsViewModel = {
  start_minimized: true,
  start_on_login: true,
  connect_on_start: false,
  connect_on_start_is_managed: false,
  account_slug: "acme-corp",
  account_slug_is_managed: false,
};

const advancedSettings: AdvancedSettingsViewModel = {
  auth_url: "https://app.firezone.dev",
  auth_url_is_managed: false,
  api_url: "wss://api.firezone.dev",
  api_url_is_managed: false,
  log_filter: "info",
  log_filter_is_managed: false,
};

const signedIn: SessionViewModel = {
  SignedIn: { account_slug: "acme-corp", actor_name: "Jane Doe" },
};

// Every screen the client can show, in the states worth eyeballing. Add an entry here
// to have it rendered; nothing else needs to change.
const screens: Record<string, React.ReactElement> = {
  "overview-signed-out": (
    <OverviewPage session="SignedOut" signIn={noop} signOut={noop} />
  ),
  "overview-loading": (
    <OverviewPage session="Loading" signIn={noop} signOut={noop} />
  ),
  "overview-signed-in": (
    <OverviewPage session={signedIn} signIn={noop} signOut={noop} />
  ),
  "general-settings": (
    <GeneralSettingsPage
      resetSettings={noop}
      saveSettings={noop}
      settings={generalSettings}
    />
  ),
  "general-settings-managed": (
    <GeneralSettingsPage
      resetSettings={noop}
      saveSettings={noop}
      settings={{
        ...generalSettings,
        account_slug_is_managed: true,
        connect_on_start_is_managed: true,
      }}
    />
  ),
  "advanced-settings": (
    <AdvancedSettingsPage
      resetSettings={noop}
      saveSettings={noop}
      settings={advancedSettings}
    />
  ),
  "advanced-settings-managed": (
    <AdvancedSettingsPage
      resetSettings={noop}
      saveSettings={noop}
      settings={{
        ...advancedSettings,
        api_url_is_managed: true,
        auth_url_is_managed: true,
        log_filter_is_managed: true,
      }}
    />
  ),
  "diagnostics-no-logs": (
    <DiagnosticsPage clearLogs={noop} exportLogs={noop} logCount={null} />
  ),
  diagnostics: (
    <DiagnosticsPage
      clearLogs={noop}
      exportLogs={noop}
      logCount={{ bytes: 3_400_000, files: 12 }}
    />
  ),
  about: <AboutPage />,
};

// `act` refuses to run unless the environment opts in.
Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

let container: HTMLDivElement;
let root: Root;

beforeEach(async () => {
  await page.viewport(CONTENT_WIDTH, CONTENT_HEIGHT);

  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
});

afterEach(() => {
  act(() => root.unmount());
  container.remove();
});

for (const [name, screen] of Object.entries(screens)) {
  test(name, async () => {
    await act(async () => {
      root.render(
        <div className="app-shell">
          <main className="min-w-0 flex-1 overflow-auto bg-page">{screen}</main>
        </div>
      );
    });

    for (const colorScheme of COLOR_SCHEMES) {
      await cdp().send("Emulation.setEmulatedMedia", {
        features: [{ name: "prefers-color-scheme", value: colorScheme }],
      });

      await page.screenshot({
        path: `../screenshots/${name}-${colorScheme}.png`,
      });
    }
  });
}
