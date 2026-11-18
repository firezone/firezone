import React from "react";
import { createRoot, Root } from "react-dom/client";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { page, userEvent } from "vitest/browser";
import { ResourceViewModel } from "../generated/bindings";
import ResourcesPage from "./ResourcesPage";

const mocks = vi.hoisted(() => ({ openUrl: vi.fn(() => Promise.resolve()) }));

vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: mocks.openUrl }));

const internet: ResourceViewModel = {
  id: "internet",
  name: "Internet Resource",
  kind: {
    type: "Internet",
    is_enabled: true,
    connection: { site: "Internet", status: "Online" },
  },
};

const wiki: ResourceViewModel = {
  id: "wiki",
  name: "Engineering wiki",
  kind: {
    type: "Dns",
    address: "wiki.example.com",
    description: "https://handbook.example.com",
    is_favorite: false,
    connection: { site: "Sydney Office", status: "Online" },
  },
};

const vpc: ResourceViewModel = {
  id: "vpc",
  name: "Production VPC",
  kind: {
    type: "Cidr",
    address: "198.51.100.0/24",
    description: "Ask the platform team",
    is_favorite: true,
    connection: { site: "Production Cloud", status: "Unknown" },
  },
};

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
  mocks.openUrl.mockClear();
});

function render() {
  const actions = {
    setFavorite: vi.fn(),
    setInternetResourceEnabled: vi.fn(),
    copy: vi.fn(),
  };

  root.render(
    <ResourcesPage
      session={{ SignedIn: { account_slug: "example", actor_name: "Jane" } }}
      resources={[internet, wiki, vpc]}
      signIn={vi.fn()}
      {...actions}
    />
  );

  return actions;
}

test.each([
  ["name", "ENGINEERING"],
  ["address", "wiki.example"],
  ["description", "Handbook"],
  ["Site", "sydney"],
])("search matches the %s, ignoring case", async (_, query) => {
  render();

  await userEvent.fill(page.getByLabelText("Search Resources"), query);

  await expect
    .element(page.getByRole("button", { name: "Engineering wiki" }))
    .toBeInTheDocument();
  await expect
    .element(page.getByRole("button", { name: "Production VPC" }))
    .not.toBeInTheDocument();
  await expect
    .element(page.getByRole("button", { name: "Internet Resource" }))
    .not.toBeInTheDocument();
});

test("a search without matches says so", async () => {
  render();

  await userEvent.fill(page.getByLabelText("Search Resources"), "nothing");

  await expect
    .element(page.getByText("No Resources match your search."))
    .toBeInTheDocument();
});

test("the star adds a Resource to the favorites", async () => {
  const { setFavorite } = render();

  await userEvent.click(page.getByRole("button", { name: "Engineering wiki" }));
  await userEvent.click(page.getByRole("button", { name: "Add to favorites" }));

  expect(setFavorite).toHaveBeenCalledExactlyOnceWith("wiki", true);
});

test("the switch disables the enabled Internet Resource", async () => {
  const { setInternetResourceEnabled } = render();

  await userEvent.click(
    page.getByRole("button", { name: "Internet Resource" })
  );
  await userEvent.click(page.getByRole("switch", { name: "Enabled" }));

  expect(setInternetResourceEnabled).toHaveBeenCalledExactlyOnceWith(false);
});

test("the Internet Resource cannot be a favorite", async () => {
  render();

  await userEvent.click(
    page.getByRole("button", { name: "Internet Resource" })
  );

  await expect
    .element(page.getByRole("switch", { name: "Enabled" }))
    .toBeInTheDocument();
  await expect
    .element(page.getByRole("button", { name: "Add to favorites" }))
    .not.toBeInTheDocument();
});

test("the address is copied on request", async () => {
  const { copy } = render();

  await userEvent.click(page.getByRole("button", { name: "Engineering wiki" }));
  await userEvent.click(page.getByRole("button", { name: "Copy address" }));

  expect(copy).toHaveBeenCalledExactlyOnceWith("wiki.example.com");
});

test("a description that is a URL opens in the browser", async () => {
  render();

  await userEvent.click(page.getByRole("button", { name: "Engineering wiki" }));
  await userEvent.click(
    page.getByRole("link", { name: "https://handbook.example.com" })
  );

  expect(mocks.openUrl).toHaveBeenCalledExactlyOnceWith(
    "https://handbook.example.com"
  );
});

test("a description that is not a URL is plain text", async () => {
  render();

  await userEvent.click(page.getByRole("button", { name: "Production VPC" }));

  await expect
    .element(page.getByText("Ask the platform team"))
    .toBeInTheDocument();
  await expect.element(page.getByRole("link")).not.toBeInTheDocument();
});
