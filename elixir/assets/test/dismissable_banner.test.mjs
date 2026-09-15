import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { beforeEach, test } from "node:test";
import { DismissableBanner } from "../js/hooks/dismissable_banner.js";

const hash = (content) => createHash("sha256").update(content).digest("hex");
const firstHash = hash("<strong>Announcement</strong>");
const secondHash = hash("Updated announcement");

beforeEach(() => {
  const values = new Map();
  globalThis.localStorage = {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
  };
});

function mount(contentHash = firstHash) {
  const el = new EventTarget();
  el.dataset = { contentHash };
  el.hidden = true;
  const hook = { ...DismissableBanner, el };
  hook.mounted();
  return hook;
}

function click(hook, dismiss = true) {
  const event = new Event("click");
  Object.defineProperty(event, "target", {
    value: { closest: () => dismiss ? {} : null },
  });
  hook.el.dispatchEvent(event);
}

test("shows new content and stores its SHA-256 when dismissed", () => {
  const hook = mount();
  assert.equal(hook.el.hidden, false);
  click(hook);
  assert.equal(hook.el.hidden, true);
  assert.equal(localStorage.getItem(`dismissedBanner:${firstHash}`), firstHash);
  assert.equal(mount().el.hidden, true);
});

test("shows changed content and remembers multiple dismissed announcements", () => {
  const hook = mount();
  click(hook);
  hook.el.dataset.contentHash = secondHash;
  hook.updated();
  assert.equal(hook.el.hidden, false);
  click(hook);
  assert.equal(mount(firstHash).el.hidden, true);
  assert.equal(mount(secondHash).el.hidden, true);
});

test("keeps dismissed content hidden after a LiveView patch", () => {
  const hook = mount();
  click(hook);
  hook.el.hidden = false;
  hook.updated();
  assert.equal(hook.el.hidden, true);
});

test("content clicks do not dismiss and destroyed hooks remove listeners", () => {
  const hook = mount();
  click(hook, false);
  assert.equal(hook.el.hidden, false);
  hook.destroyed();
  click(hook);
  assert.equal(hook.el.hidden, false);
});

test("works when local storage reads and writes fail", () => {
  globalThis.localStorage = {
    getItem() { throw new Error("Storage blocked"); },
    setItem() { throw new Error("Storage blocked"); },
  };
  const hook = mount();
  assert.equal(hook.el.hidden, false);
  click(hook);
  hook.updated();
  assert.equal(hook.el.hidden, true);
  hook.el.dataset.contentHash = secondHash;
  hook.updated();
  assert.equal(hook.el.hidden, false);
});
