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
  const unlockDeveloperSettings = vi.fn();
  root.render(<AboutPage unlockDeveloperSettings={unlockDeveloperSettings} />);
  const logo = page.getByRole("button", { name: "Firezone Logo" });

  for (let i = 0; i < 6; i++) await userEvent.click(logo);
  expect(unlockDeveloperSettings).not.toHaveBeenCalled();

  await userEvent.click(logo);
  expect(unlockDeveloperSettings).toHaveBeenCalledOnce();
});
