import React from "react";
import { createRoot, Root } from "react-dom/client";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { page, userEvent } from "vitest/browser";
import AboutPage from "./AboutPage";

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

test("clicking the logo seven times unlocks the developer settings", async () => {
  const loadDeveloperSettings = () => Promise.resolve({ unlocked: false });
  const saveDeveloperSettings = vi.fn();
  root.render(
    <AboutPage
      loadDeveloperSettings={loadDeveloperSettings}
      saveDeveloperSettings={saveDeveloperSettings}
      resetConnlib={() => {}}
    />
  );
  const logo = page.getByRole("button", { name: "Firezone Logo" });

  for (let i = 0; i < 6; i++) await userEvent.click(logo);
  await expect
    .element(page.getByText("Developer settings", { exact: true }))
    .not.toBeInTheDocument();

  await userEvent.click(logo);
  await expect
    .element(page.getByText("Developer settings", { exact: true }))
    .toBeInTheDocument();
  expect(saveDeveloperSettings).toHaveBeenCalledWith({ unlocked: true });
});

test("hiding the developer settings locks them again", async () => {
  const loadDeveloperSettings = () => Promise.resolve({ unlocked: true });
  const saveDeveloperSettings = vi.fn();
  root.render(
    <AboutPage
      loadDeveloperSettings={loadDeveloperSettings}
      saveDeveloperSettings={saveDeveloperSettings}
      resetConnlib={() => {}}
    />
  );

  await userEvent.click(page.getByRole("button", { name: "Hide" }));

  await expect
    .element(page.getByText("Developer settings", { exact: true }))
    .not.toBeInTheDocument();
  expect(saveDeveloperSettings).toHaveBeenCalledWith({ unlocked: false });
});
