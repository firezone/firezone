import React from "react";
import { createRoot, Root } from "react-dom/client";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { page, userEvent } from "vitest/browser";
import DiagnosticsPage from "./DiagnosticsPage";

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

test("a rejected log filter shows the returned message and keeps the draft", async () => {
  const saveLogFilter = vi.fn().mockResolvedValue({
    status: "error",
    error: "Invalid log filter: invalid filter directive",
  });

  root.render(
    <DiagnosticsPage
      logCount={null}
      logFilter={{ log_filter: "info", log_filter_is_managed: false }}
      exportLogs={() => {}}
      clearLogs={() => {}}
      saveLogFilter={saveLogFilter}
    />
  );

  await userEvent.fill(
    page.getByLabelText("Log Filter"),
    "info,connlib=nonsense"
  );
  await userEvent.keyboard("{Enter}");

  await expect
    .element(page.getByText("Invalid log filter: invalid filter directive"))
    .toBeInTheDocument();
  await expect
    .element(page.getByLabelText("Log Filter"))
    .toHaveAttribute("aria-invalid", "true");
  await expect
    .element(page.getByLabelText("Log Filter"))
    .toHaveValue("info,connlib=nonsense");
  expect(saveLogFilter).toHaveBeenCalledWith("info,connlib=nonsense");
});

test("an empty log filter is saved", async () => {
  const saveLogFilter = vi.fn().mockResolvedValue({ status: "ok", data: null });

  root.render(
    <DiagnosticsPage
      logCount={null}
      logFilter={{ log_filter: "info", log_filter_is_managed: false }}
      exportLogs={() => {}}
      clearLogs={() => {}}
      saveLogFilter={saveLogFilter}
    />
  );

  await userEvent.fill(page.getByLabelText("Log Filter"), "");
  await userEvent.keyboard("{Enter}");

  expect(saveLogFilter).toHaveBeenCalledWith("");
  await expect.element(page.getByLabelText("Log Filter")).toHaveValue("");
  await expect
    .element(page.getByLabelText("Log Filter"))
    .not.toHaveAttribute("aria-invalid", "true");
});

test("Clear Logs cancels without deleting and runs only after confirmation", async () => {
  const clearLogs = vi.fn();
  root.render(
    <DiagnosticsPage
      logCount={null}
      logFilter={{ log_filter: "info", log_filter_is_managed: false }}
      exportLogs={() => {}}
      clearLogs={clearLogs}
      saveLogFilter={vi.fn()}
    />
  );
  const trigger = page.getByRole("button", { name: "Clear Logs" });
  const dialog = page.getByRole("dialog", { name: "Delete all log files?" });

  await userEvent.click(trigger);
  await expect.element(dialog).toBeVisible();
  await expect
    .element(page.getByRole("button", { name: "Cancel", exact: true }))
    .toHaveFocus();
  expect(clearLogs).not.toHaveBeenCalled();
  await userEvent.keyboard("{Escape}");
  await expect.element(dialog).not.toBeInTheDocument();
  await expect.element(trigger).toHaveFocus();
  expect(clearLogs).not.toHaveBeenCalled();

  await userEvent.click(trigger);
  await userEvent.click(
    page.getByRole("button", { name: "Cancel", exact: true })
  );
  await expect.element(trigger).toHaveFocus();
  expect(clearLogs).not.toHaveBeenCalled();

  await userEvent.click(trigger);
  await userEvent.click(
    page.getByRole("button", { name: "Clear", exact: true })
  );
  expect(clearLogs).toHaveBeenCalledTimes(1);
  await expect.element(dialog).not.toBeInTheDocument();
  await expect.element(trigger).toHaveFocus();

  await userEvent.click(trigger);
  await userEvent.dblClick(
    page.getByRole("button", { name: "Clear", exact: true })
  );
  expect(clearLogs).toHaveBeenCalledTimes(2);
  await expect.element(dialog).not.toBeInTheDocument();
});
