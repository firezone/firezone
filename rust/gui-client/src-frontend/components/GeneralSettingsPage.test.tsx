import React from "react";
import { createRoot, Root } from "react-dom/client";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { page, userEvent } from "vitest/browser";
import { GeneralSettingsViewModel } from "../generated/bindings";
import GeneralSettingsPage from "./GeneralSettingsPage";

const usSettings: GeneralSettingsViewModel = {
  start_minimized: true,
  start_on_login: false,
  connect_on_start: false,
  connect_on_start_is_managed: false,
  account_slug: "",
  account_slug_is_managed: false,
  portal: "CloudUs",
  auth_url: "https://app.firezone.dev/",
  auth_url_is_managed: false,
  api_url: "wss://api.firezone.dev/",
  api_url_is_managed: false,
  custom_auth_url: "https://app.firezone.dev/",
  custom_api_url: "wss://api.firezone.dev/",
  signed_in_with: null,
};

const customSettings: GeneralSettingsViewModel = {
  ...usSettings,
  portal: "Custom",
  auth_url: "https://firezone.example.com/",
  api_url: "wss://api.firezone.example.com/",
  custom_auth_url: "https://firezone.example.com/",
  custom_api_url: "wss://api.firezone.example.com/",
};

// No `act`: the user events below arrive from outside React, so the assertions retry until
// the page has caught up instead.

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

async function render(settings: GeneralSettingsViewModel) {
  const saveSettings = vi.fn();

  root.render(
    <GeneralSettingsPage
      settings={settings}
      saveSettings={saveSettings}
      resetSettings={() => {}}
    />
  );
  await expect
    .element(page.getByLabelText("Control plane"))
    .toBeInTheDocument();

  return saveSettings;
}

test("picking Custom saves the last saved custom URLs", async () => {
  const saveSettings = await render({
    ...usSettings,
    custom_auth_url: "https://firezone.example.com/",
    custom_api_url: "wss://api.firezone.example.com/",
  });

  await userEvent.selectOptions(page.getByLabelText("Control plane"), "Custom");

  await vi.waitFor(() =>
    expect(saveSettings).toHaveBeenCalledWith(
      expect.objectContaining({
        portal: "Custom",
        auth_url: "https://firezone.example.com/",
        api_url: "wss://api.firezone.example.com/",
      })
    )
  );
});

test("leaving a valid URL saves it", async () => {
  const saveSettings = await render(customSettings);

  await userEvent.fill(
    page.getByLabelText("Auth URL"),
    "https://other.example.com/"
  );
  await userEvent.click(page.getByLabelText("Account slug"));

  await vi.waitFor(() =>
    expect(saveSettings).toHaveBeenCalledWith(
      expect.objectContaining({
        portal: "Custom",
        auth_url: "https://other.example.com/",
        api_url: "wss://api.firezone.example.com/",
      })
    )
  );
});

test("leaving a local http:// auth URL saves it", async () => {
  const saveSettings = await render(customSettings);

  await userEvent.fill(
    page.getByLabelText("Auth URL"),
    "http://localhost:4000"
  );
  await userEvent.click(page.getByLabelText("Account slug"));

  await vi.waitFor(() =>
    expect(saveSettings).toHaveBeenCalledWith(
      expect.objectContaining({ auth_url: "http://localhost:4000" })
    )
  );
});

test("leaving a local ws:// API URL saves it", async () => {
  const saveSettings = await render(customSettings);

  await userEvent.fill(page.getByLabelText("API URL"), "ws://localhost:8081");
  await userEvent.click(page.getByLabelText("Account slug"));

  await vi.waitFor(() =>
    expect(saveSettings).toHaveBeenCalledWith(
      expect.objectContaining({ api_url: "ws://localhost:8081" })
    )
  );
});

test.each(["not a url", "ftp://x", "wss://api.firezone.example.com/"])(
  "leaving %s as the auth URL shows an error and saves nothing",
  async (url) => {
    const saveSettings = await render(customSettings);

    await userEvent.fill(page.getByLabelText("Auth URL"), url);
    await userEvent.click(page.getByLabelText("Account slug"));

    await expect
      .element(page.getByText("Enter a valid http:// or https:// URL"))
      .toBeInTheDocument();
    await expect
      .element(page.getByLabelText("Auth URL"))
      .toHaveAttribute("aria-invalid", "true");
    await expect.element(page.getByLabelText("Auth URL")).toHaveValue(url);
    expect(saveSettings).not.toHaveBeenCalled();
  }
);

test("leaving an https:// API URL shows an error and saves nothing", async () => {
  const saveSettings = await render(customSettings);

  await userEvent.fill(page.getByLabelText("API URL"), "https://x.example.com");
  await userEvent.click(page.getByLabelText("Account slug"));

  await expect
    .element(page.getByText("Enter a valid ws:// or wss:// URL"))
    .toBeInTheDocument();
  expect(saveSettings).not.toHaveBeenCalled();
});

const pendingNote =
  "Changes to the account slug or control plane take effect after you sign out and sign in again.";

const signedIn: GeneralSettingsViewModel = {
  ...usSettings,
  account_slug: "firezone",
  signed_in_with: {
    account_slug: "firezone",
    portal: "CloudUs",
    auth_url: "https://app.firezone.dev/",
    api_url: "wss://api.firezone.dev/",
  },
};

test("editing the account slug while signed out shows no sign-in note", async () => {
  await render({ ...signedIn, signed_in_with: null });

  await userEvent.fill(page.getByLabelText("Account slug"), "other");

  await expect
    .element(page.getByLabelText("Account slug"))
    .toHaveValue("other");
  await expect.element(page.getByText(pendingNote)).not.toBeInTheDocument();
});

test("a draft account slug shows the sign-in note until it is reverted", async () => {
  await render(signedIn);

  await expect.element(page.getByText(pendingNote)).not.toBeInTheDocument();

  await userEvent.fill(page.getByLabelText("Account slug"), "other");
  await expect.element(page.getByText(pendingNote)).toBeInTheDocument();

  await userEvent.fill(page.getByLabelText("Account slug"), "firezone");
  await expect.element(page.getByText(pendingNote)).not.toBeInTheDocument();
});

test("a saved portal other than the signed-in one shows the sign-in note", async () => {
  await render({ ...signedIn, portal: "CloudEu" });

  await expect.element(page.getByText(pendingNote)).toBeInTheDocument();
});

test("a draft custom URL shows the sign-in note", async () => {
  await render({
    ...customSettings,
    signed_in_with: {
      account_slug: "",
      portal: "Custom",
      auth_url: "https://firezone.example.com/",
      api_url: "wss://api.firezone.example.com/",
    },
  });

  await expect.element(page.getByText(pendingNote)).not.toBeInTheDocument();

  await userEvent.fill(
    page.getByLabelText("Auth URL"),
    "https://other.example.com"
  );
  await expect.element(page.getByText(pendingNote)).toBeInTheDocument();
});

test("Escape puts back the saved value", async () => {
  const saveSettings = await render(customSettings);

  await userEvent.fill(page.getByLabelText("Auth URL"), "not a url");
  await userEvent.keyboard("{Escape}");

  await expect
    .element(page.getByLabelText("Auth URL"))
    .toHaveValue("https://firezone.example.com/");
  expect(saveSettings).not.toHaveBeenCalled();
});

test("picking Custom without saved custom URLs shows the current ones", async () => {
  await render(usSettings);

  await userEvent.selectOptions(page.getByLabelText("Control plane"), "Custom");

  await expect
    .element(page.getByLabelText("Auth URL"))
    .toHaveValue("https://app.firezone.dev/");
  await expect
    .element(page.getByLabelText("API URL"))
    .toHaveValue("wss://api.firezone.dev/");
});

test("a cloud portal hides the URL fields", async () => {
  await render(usSettings);

  await expect.element(page.getByLabelText("Auth URL")).not.toBeInTheDocument();
  await expect.element(page.getByLabelText("API URL")).not.toBeInTheDocument();
});
