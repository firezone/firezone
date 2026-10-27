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
  await expect.element(page.getByLabelText("Portal")).toBeInTheDocument();

  return saveSettings;
}

test("picking Custom saves the last saved custom URLs", async () => {
  const saveSettings = await render({
    ...usSettings,
    custom_auth_url: "https://firezone.example.com/",
    custom_api_url: "wss://api.firezone.example.com/",
  });

  await userEvent.selectOptions(page.getByLabelText("Portal"), "Custom");

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

test("leaving an invalid URL shows an error and saves nothing", async () => {
  const saveSettings = await render(customSettings);

  await userEvent.fill(page.getByLabelText("Auth URL"), "not a url");
  await userEvent.click(page.getByLabelText("Account slug"));

  await expect
    .element(page.getByText("Enter a valid https:// URL"))
    .toBeInTheDocument();
  await expect
    .element(page.getByLabelText("Auth URL"))
    .toHaveAttribute("aria-invalid", "true");
  await expect
    .element(page.getByLabelText("Auth URL"))
    .toHaveValue("not a url");
  expect(saveSettings).not.toHaveBeenCalled();
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

  await userEvent.selectOptions(page.getByLabelText("Portal"), "Custom");

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
