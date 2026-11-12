import React from "react";
import { createRoot, Root } from "react-dom/client";
import { MemoryRouter } from "react-router";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { page, userEvent } from "vitest/browser";
import type { DeveloperSettings } from "../generated/bindings";

const mocks = vi.hoisted(() => {
  function deferred<T>() {
    let resolve!: (value: T) => void;
    const promise = new Promise<T>((resolvePromise) => {
      resolve = resolvePromise;
    });

    return { promise, resolve };
  }

  const subscriptions = Array.from({ length: 6 }, () => deferred<() => void>());
  const listen = subscriptions.map(({ promise }) => vi.fn(() => promise));

  return {
    subscriptions,
    updateState: vi.fn(),
    setDeveloperSettingsUnlocked: vi.fn(),
    events: {
      sessionChanged: { listen: listen[0] },
      generalSettingsChanged: { listen: listen[1] },
      logFilterChanged: { listen: listen[2] },
      logsRecounted: { listen: listen[3] },
      x509CertificateChanged: { listen: listen[4] },
      developerSettingsChanged: {
        listen: vi.fn<
          (
            listener: (event: { payload: DeveloperSettings }) => void
          ) => Promise<() => void>
        >(() => subscriptions[5].promise),
      },
    },
  };
});

vi.mock("../generated/bindings", () => ({
  commands: {
    applyClientSettings: vi.fn(),
    applyLogFilter: vi.fn(),
    clearLogs: vi.fn(),
    exportLogs: vi.fn(),
    resetClientSettings: vi.fn(),
    resetConnlib: vi.fn(),
    setDeveloperSettingsUnlocked: mocks.setDeveloperSettingsUnlocked,
    signIn: vi.fn(),
    signOut: vi.fn(),
    updateState: mocks.updateState,
  },
  events: mocks.events,
}));

import App from "./App";

let container: HTMLDivElement;
let root: Root;

beforeEach(() => {
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
});

afterEach(() => {
  root.unmount();
  container.remove();
});

test("requests initial state only after every event listener is registered", async () => {
  root.render(
    <MemoryRouter initialEntries={["/general-settings"]}>
      <App />
    </MemoryRouter>
  );

  await vi.waitFor(() =>
    expect(mocks.events.x509CertificateChanged.listen).toHaveBeenCalled()
  );
  expect(mocks.updateState).not.toHaveBeenCalled();

  for (const subscription of mocks.subscriptions) {
    subscription.resolve(vi.fn());
  }

  await vi.waitFor(() => expect(mocks.updateState).toHaveBeenCalledOnce());
});

test("hiding the developer settings removes their page and returns to About", async () => {
  const { listen } = mocks.events.developerSettingsChanged;
  listen.mockClear();
  root.render(
    <MemoryRouter initialEntries={["/developer-settings"]}>
      <App />
    </MemoryRouter>
  );
  await vi.waitFor(() => expect(listen).toHaveBeenCalledOnce());
  const [listener] = listen.mock.calls[0];
  listener({ payload: { unlocked: true } });
  const developerSettingsLink = page.getByRole("link", { name: "Developer" });
  await expect.element(developerSettingsLink).toBeInTheDocument();

  await userEvent.click(
    page.getByRole("button", { name: "Hide Developer Settings" })
  );
  expect(mocks.setDeveloperSettingsUnlocked).toHaveBeenCalledWith(false);
  listener({ payload: { unlocked: false } });

  await expect
    .element(page.getByRole("button", { name: "Firezone Logo" }))
    .toBeInTheDocument();
  await expect.element(developerSettingsLink).not.toBeInTheDocument();
});
