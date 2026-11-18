import { clearMocks, mockIPC, mockWindows } from "@tauri-apps/api/mocks";
// Teaches `cdp()` the Playwright session shape; the provider augments `vitest/browser`.
import type {} from "@vitest/browser-playwright";
import React, { act } from "react";
import { createRoot, Root } from "react-dom/client";
import { MemoryRouter } from "react-router";
import { afterEach, beforeEach, test, vi } from "vitest";
import { cdp, page, userEvent } from "vitest/browser";
import App from "./components/App";
import {
  events,
  FileCount,
  GeneralSettingsViewModel,
  LogFilterViewModel,
  ResourceViewModel,
  SessionViewModel,
  X509Certificate,
  X509DetailField,
  X509ValidationError,
} from "./generated/bindings";
import "./main.css";

// The window the client actually opens, from `tauri.conf.json`.
const WINDOW_WIDTH = 900;
const WINDOW_HEIGHT = 500;

const COLOR_SCHEMES = ["light", "dark"] as const;

// The state the Tunnel service would have pushed by the time the window is shown. A screen
// leaves a field out to render what the user sees before that event arrives.
interface Screen {
  route: string;
  // The buttons to click, in order.
  click?: string[];
  session?: SessionViewModel;
  resources?: ResourceViewModel[];
  generalSettings?: GeneralSettingsViewModel;
  logFilter?: LogFilterViewModel;
  /// The certificate the keystore holds, when the device trust tab is available.
  deviceTrustCertificate?: X509Certificate;
  logCount?: FileCount;
  // Whether the user unlocked the developer settings, which adds their tab.
  developerSettingsUnlocked?: boolean;
  // A field to type into and press Enter on, for a screen that shows a rejected value.
  input?: { label: string; value: string };
  // The colour schemes to render, when not all of them.
  colorSchemes?: readonly (typeof COLOR_SCHEMES)[number][];
}

const generalSettings: GeneralSettingsViewModel = {
  start_minimized: true,
  start_on_login: true,
  start_on_login_is_managed: false,
  connect_on_start: false,
  connect_on_start_is_managed: false,
  account_slug: "example-corp",
  account_slug_is_managed: false,
  control_plane: "CloudUs",
  auth_url: "https://app.firezone.dev/",
  auth_url_is_managed: false,
  api_url: "wss://api.firezone.dev/",
  api_url_is_managed: false,
  custom_auth_url: "https://app.firezone.dev/",
  custom_api_url: "wss://api.firezone.dev/",
  signed_in_with: null,
};

const logFilter: LogFilterViewModel = {
  log_filter: "info",
  log_filter_is_managed: false,
};

const signedIn: SessionViewModel = {
  SignedIn: { account_slug: "example-corp", actor_name: "Jane Doe" },
};

function device(
  client_id: string,
  name: string,
  tunnel_ipv4: string,
  tunnel_ipv6: string
) {
  return {
    hostname: `${name}.firezone.network`,
    tunnel_ipv4,
    tunnel_ipv6,
    client_name: name,
    client_id,
  };
}

// The Resources the mock Tunnel service serves (`mock_tunnel.rs`), plus a few that stress
// the layout.
const resources: ResourceViewModel[] = [
  {
    id: "425233f2-a1cb-4b7d-84f3-850367fa122a",
    name: "Internet Resource",
    kind: {
      type: "Internet",
      is_enabled: true,
      connection: { site: "Internet", status: "Online" },
    },
  },
  {
    id: "0854dca1-2c5b-468a-be85-0eec2f02a211",
    name: "Engineering wiki",
    kind: {
      type: "Dns",
      address: "wiki.example.com",
      description: "https://wiki.example.com",
      is_favorite: true,
      connection: { site: "Sydney Office", status: "Online" },
    },
  },
  {
    id: "92da16a4-0eb2-45c2-b882-8573aad73921",
    name: "Git server",
    kind: {
      type: "Dns",
      address: "git.example.com",
      description: null,
      is_favorite: false,
      connection: { site: "Production Cloud", status: "Unknown" },
    },
  },
  {
    id: "ed3778b9-dd41-4312-b616-028b0bbaff1c",
    name: "Internal services",
    kind: {
      type: "Dns",
      address: "*.svc.example.com",
      description: null,
      is_favorite: false,
      connection: { site: "Production Cloud", status: "Unknown" },
    },
  },
  {
    id: "5b1d1bb5-5b0c-4a53-a4d5-3a9b2c1f7e10",
    name: "Customer data warehouse (read replica, EU West)",
    kind: {
      type: "Dns",
      address: "warehouse-replica.eu-west-1.analytics.internal.example.com",
      description: "Read-only. Ask the data team for credentials.",
      is_favorite: false,
      connection: { site: "Production Cloud", status: "Online" },
    },
  },
  {
    id: "be575d17-b0b3-40c9-ac34-e1ec3064d75a",
    name: "Office network",
    kind: {
      type: "Cidr",
      address: "192.0.2.0/24",
      description: null,
      is_favorite: true,
      connection: { site: "Sydney Office", status: "Online" },
    },
  },
  {
    id: "8900accd-e39d-4705-ac7c-2189c59b4a1c",
    name: "Production VPC",
    kind: {
      type: "Cidr",
      address: "198.51.100.0/24",
      description: null,
      is_favorite: false,
      connection: { site: "Production Cloud", status: "Unknown" },
    },
  },
  {
    id: "6b15c815-cefc-4128-8ab0-d9d6a526bbc7",
    name: "Lab test bench",
    kind: {
      type: "Cidr",
      address: "203.0.113.0/24",
      description: null,
      is_favorite: false,
      connection: { site: "Hardware Lab", status: "Offline" },
    },
  },
  {
    id: "c193c2fd-b346-44fb-a7ae-e2b74c492482",
    name: "Build farm",
    kind: {
      type: "DevicePool",
      is_favorite: false,
      devices: [
        device(
          "47e9e79b-e4eb-4444-af14-ec24c6a2afc2",
          "build-runner-02",
          "100.64.7.41",
          "fd00:2021:1111::29"
        ),
        device(
          "db8221d1-0277-4f05-b0a8-22b32a5a9a46",
          "build-runner-03",
          "100.64.7.42",
          "fd00:2021:1111::2a"
        ),
      ],
    },
  },
  {
    id: "bc643791-3b90-4d41-9cac-753af623f274",
    name: "Lab hardware",
    kind: {
      type: "DevicePool",
      is_favorite: true,
      devices: [
        device(
          "a21c9663-4d0e-4f4a-a8fa-48790b1e5cef",
          "bench-controller-01",
          "100.64.3.18",
          "fd00:2021:1111::12"
        ),
        device(
          "4a6f80e6-5322-4202-a1ac-1e897aa826a5",
          "lab-probe-01",
          "100.64.19.87",
          "fd00:2021:1111::3c2"
        ),
        device(
          "99fd7f50-02aa-4ebd-aac3-b9b914c4aebb",
          "lab-probe-02",
          "100.64.19.88",
          "fd00:2021:1111::3c3"
        ),
        device(
          "ef39322d-65e2-4dea-af50-6fd4c61a72a6",
          "sensor-hub-01",
          "100.64.19.89",
          "fd00:2021:1111::3c4"
        ),
        device(
          "e8dc5d0d-93ac-4e1b-9532-866dda67ce5b",
          "vision-rig-01",
          "100.64.19.86",
          "fd00:2021:1111::3c1"
        ),
      ],
    },
  },
  {
    id: "4cbe2883-8ed8-4b97-a119-07db08d6aa6c",
    name: "Shared storage",
    kind: { type: "DevicePool", is_favorite: false, devices: [] },
  },
];

// The subject common name Firezone's MDM integrations provision, from
// `x509_keystore::SUBJECT_COMMON_NAME`.
const SUBJECT_CN = "dev.firezone.device-trust";

// One certificate as the diagnostics describe it. Every value is fixed: a field read from the
// clock, or from a certificate minted at test time, would put a new image in the gallery on
// every run.
interface Certificate {
  commonName: string;
  subject: string;
  issuer: string;
  mdmDeviceId: Row;
  deviceSerial: Row;
  serialNumber: string;
  notBefore: string;
  notAfter: Row;
  signingAlgorithm: Row;
  fingerprint: string;
}

// One row as the parser hands it over: what the certificate said, and what is wrong with it.
interface Row {
  value: string | null;
  problem?: X509ValidationError;
}

function row(label: string, { value, problem }: Row): X509DetailField {
  return { label, value, problem: problem ?? null };
}

function present(value: string): Row {
  return { value };
}

// The rows in the order `x509_claims::ParsedCertificate::detail_fields` builds them.
function loadedCertificate(certificate: Certificate): X509Certificate {
  // `x509_claims::ParsedCertificate::detail_fields` reads the rows with a problem first, so a
  // mock that left them in place would draw a screen the client cannot produce.
  const fields = [
    row("Common Name", present(certificate.commonName)),
    row("Subject", present(certificate.subject)),
    row("Issuer", present(certificate.issuer)),
    row("MDM Device ID", certificate.mdmDeviceId),
    row("Device Serial", certificate.deviceSerial),
    row("Serial Number", present(certificate.serialNumber)),
    row("Not Before", present(certificate.notBefore)),
    row("Not After", certificate.notAfter),
    row("Signing Algorithm", certificate.signingAlgorithm),
    row("SHA-256 Fingerprint", present(certificate.fingerprint)),
  ];

  return {
    fields: [
      ...fields.filter((field) => field.problem !== null),
      ...fields.filter((field) => field.problem === null),
    ],
  };
}

// A device identity an MDM enrolled into the Windows certificate stores.
const windowsCertificate: Certificate = {
  commonName: SUBJECT_CN,
  subject: `O=Example Corp, CN=${SUBJECT_CN}`,
  issuer: "DC=com, DC=example, CN=Example Corp Issuing CA 1",
  mdmDeviceId: present("9a1c7d4e-5f60-4b28-8c3a-2d5e7f9b0c14"),
  deviceSerial: present("PF2X9K7L"),
  serialNumber: "3a:68:e8:18:bf:83:6b:20:c4:37:16:ec:96:d2:7a:a4",
  notBefore: "Mar 12 09:12:44 2026 +00:00",
  notAfter: present("Jun 14 09:12:44 2028 +00:00"),
  signingAlgorithm: present("SHA256withRSA"),
  fingerprint:
    "90:E4:45:C9:E2:8E:8F:5B:57:D2:30:90:8C:6F:B2:3D:CE:A1:61:CA:96:3E:BF:B2:8E:E7:3D:A9:CF:70:DD:B7",
};

// Every screen the client can show, in the states worth eyeballing.
const screens: Record<string, Screen> = {
  "overview-signed-out": { route: "/overview", session: "SignedOut" },
  "overview-loading": { route: "/overview", session: "Loading" },
  "overview-signed-in": { route: "/overview", session: signedIn },
  "resources-signed-out": { route: "/resources", session: "SignedOut" },
  "resources-empty": { route: "/resources", session: signedIn, resources: [] },
  resources: { route: "/resources", session: signedIn, resources },
  "resources-dns": {
    route: "/resources",
    session: signedIn,
    resources,
    click: ["Engineering wiki"],
  },
  "resources-offline": {
    route: "/resources",
    session: signedIn,
    resources,
    click: ["Lab test bench"],
  },
  "resources-internet": {
    route: "/resources",
    session: signedIn,
    resources,
    click: ["Internet Resource"],
  },
  "resources-device-pool": {
    route: "/resources",
    session: signedIn,
    resources,
    click: ["Lab hardware", "bench-controller-01.firezone.network"],
  },
  "resources-search": {
    route: "/resources",
    session: signedIn,
    resources,
    input: { label: "Search Resources", value: "production" },
    click: ["Customer data warehouse"],
  },
  "general-settings": { route: "/general-settings", generalSettings },
  "general-settings-custom": {
    route: "/general-settings",
    generalSettings: {
      ...generalSettings,
      control_plane: "Custom",
      auth_url: "https://firezone.example.com/",
      api_url: "wss://api.firezone.example.com/",
    },
  },
  "general-settings-invalid-url": {
    route: "/general-settings",
    generalSettings: {
      ...generalSettings,
      control_plane: "Custom",
      auth_url: "https://firezone.example.com/",
      api_url: "wss://api.firezone.example.com/",
    },
    input: { label: "Auth URL", value: "firezone.example.com" },
  },
  "general-settings-pending-sign-in": {
    route: "/general-settings",
    generalSettings: {
      ...generalSettings,
      signed_in_with: {
        account_slug: "example-corp",
        control_plane: "CloudEu",
        auth_url: "https://eu.app.firezone.dev/",
        api_url: "wss://eu.api.firezone.dev/",
      },
    },
  },
  "general-settings-managed": {
    route: "/general-settings",
    generalSettings: {
      ...generalSettings,
      account_slug_is_managed: true,
      start_on_login_is_managed: true,
      connect_on_start_is_managed: true,
      control_plane: "CloudEu",
      auth_url: "https://eu.app.firezone.dev/",
      auth_url_is_managed: true,
      api_url: "wss://eu.api.firezone.dev/",
      api_url_is_managed: true,
    },
  },
  "device-trust-happy": {
    route: "/device-trust",
    deviceTrustCertificate: loadedCertificate(windowsCertificate),
  },
  "diagnostics-no-logs": { route: "/diagnostics" },
  diagnostics: {
    route: "/diagnostics",
    logCount: { bytes: 3_400_000, files: 12 },
    logFilter,
  },
  "diagnostics-clear-confirmation": {
    route: "/diagnostics",
    logCount: { bytes: 3_400_000, files: 17 },
    logFilter,
    click: ["Clear Logs"],
  },
  "settings-reset-confirmation": {
    route: "/general-settings",
    generalSettings,
    click: ["Reset to Defaults"],
  },
  "diagnostics-managed": {
    route: "/diagnostics",
    logCount: { bytes: 3_400_000, files: 12 },
    logFilter: { log_filter: "debug", log_filter_is_managed: true },
  },
  about: { route: "/about" },
  "developer-settings": {
    route: "/developer-settings",
    developerSettingsUnlocked: true,
    colorSchemes: ["light"],
  },
};

// An animation makes the captured frame depend on wall-clock timing: the overview's
// loading spinner would sit at a different angle in every run and its image would churn.
const frozen = document.createElement("style");
frozen.textContent =
  "*, *::before, *::after { animation: none !important; transition: none !important; }";
document.head.append(frozen);

// `act` refuses to run unless the environment opts in.
Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

let container: HTMLDivElement;
let root: Root;

beforeEach(async () => {
  await page.viewport(WINDOW_WIDTH, WINDOW_HEIGHT);

  // The app talks to the Tunnel service over Tauri's IPC, which a browser does not have.
  // Every command is answered with `undefined`; the screens are driven by events instead.
  mockIPC(() => {}, { shouldMockEvents: true });
  mockWindows("main");

  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
});

afterEach(async () => {
  // The unmount detaches the event listeners asynchronously, so the mocks have to outlive it.
  await act(async () => {
    root.unmount();
  });
  container.remove();
  clearMocks();
});

// A screenshot taken straight after the last DOM mutation can catch the frame before it,
// and the emulated colour scheme reaches the page a moment after the CDP call returns.
async function settle() {
  await document.fonts.ready;
  await new Promise((resolve) =>
    requestAnimationFrame(() => requestAnimationFrame(resolve))
  );
}

async function useColorScheme(colorScheme: (typeof COLOR_SCHEMES)[number]) {
  await cdp().send("Emulation.setEmulatedMedia", {
    features: [{ name: "prefers-color-scheme", value: colorScheme }],
  });

  const query = window.matchMedia(`(prefers-color-scheme: ${colorScheme})`);
  await vi.waitUntil(() => query.matches);
}

for (const [name, screen] of Object.entries(screens)) {
  for (const colorScheme of screen.colorSchemes ?? COLOR_SCHEMES) {
    test(`${name}-${colorScheme}`, async () => {
      await useColorScheme(colorScheme);

      await act(async () => {
        root.render(
          <MemoryRouter initialEntries={[screen.route]}>
            <App />
          </MemoryRouter>
        );
      });

      await act(async () => {
        if (screen.session) await events.sessionChanged.emit(screen.session);
        if (screen.resources)
          await events.resourcesChanged.emit(screen.resources);
        if (screen.generalSettings)
          await events.generalSettingsChanged.emit(screen.generalSettings);
        if (screen.logFilter)
          await events.logFilterChanged.emit(screen.logFilter);
        if (screen.deviceTrustCertificate)
          await events.x509CertificateChanged.emit(
            screen.deviceTrustCertificate
          );
        if (screen.logCount) await events.logsRecounted.emit(screen.logCount);
        await events.developerSettingsChanged.emit({
          unlocked: screen.developerSettingsUnlocked ?? false,
          force_relayed_connections: false,
        });
      });

      await settle();

      if (screen.input) {
        const { label, value } = screen.input;
        await act(async () => {
          await userEvent.fill(page.getByLabelText(label), value);
          await userEvent.keyboard("{Enter}");
        });
        await settle();
      }

      for (const name of screen.click ?? []) {
        const button = page.getByRole("button", { name });
        await act(async () => {
          await button.click();
        });
        await settle();
      }

      await page.screenshot({
        path: `../screenshots/${name}-${colorScheme}.png`,
      });
    });
  }
}
