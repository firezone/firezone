import { clearMocks, mockIPC, mockWindows } from "@tauri-apps/api/mocks";
// Teaches `cdp()` the Playwright session shape; the provider augments `vitest/browser`.
import type {} from "@vitest/browser-playwright";
import React, { act } from "react";
import { createRoot, Root } from "react-dom/client";
import { MemoryRouter } from "react-router";
import { afterEach, beforeEach, test, vi } from "vitest";
import { cdp, page } from "vitest/browser";
import App from "./components/App";
import {
  AdvancedSettingsViewModel,
  events,
  FileCount,
  GeneralSettingsViewModel,
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
  session?: SessionViewModel;
  generalSettings?: GeneralSettingsViewModel;
  advancedSettings?: AdvancedSettingsViewModel;
  /// The certificate the keystore holds, when the device trust tab is available.
  x509?: X509Certificate;
  logCount?: FileCount;
  // Label of a field to leave the pointer over, for a screen whose tooltip is the point.
  hover?: string;
}

const generalSettings: GeneralSettingsViewModel = {
  start_minimized: true,
  start_on_login: true,
  connect_on_start: false,
  connect_on_start_is_managed: false,
  account_slug: "example-corp",
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

// The subject common name Firezone's MDM integrations provision, from
// `x509_keystore::SUBJECT_COMMON_NAME`.
const SUBJECT_CN = "dev.firezone.device-trust";

// The actor the provisioned certificate names, which the overview offers to connect as.
const ACTOR_EMAIL = "jane.doe@example.com";

// One certificate as the diagnostics describe it. Every value is fixed: a field read from the
// clock, or from a certificate minted at test time, would put a new image in the gallery on
// every run.
interface Certificate {
  commonName: string;
  subject: string;
  issuer: string;
  actorEmail: Row;
  accountId: Row;
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
    row("Actor Email", certificate.actorEmail),
    row("Account ID", certificate.accountId),
    row("MDM Device ID", certificate.mdmDeviceId),
    row("Device Serial", certificate.deviceSerial),
    row("Serial Number", present(certificate.serialNumber)),
    row("Not Before", present(certificate.notBefore)),
    row("Not After", certificate.notAfter),
    row("Signing Algorithm", certificate.signingAlgorithm),
    row("SHA-256 Fingerprint", present(certificate.fingerprint)),
  ];

  // An identity is claimed by a carried identity attribute, valid or not:
  // `x509_claims::ParsedCertificate::identity`.
  const claimed =
    certificate.actorEmail.value !== null ||
    certificate.actorEmail.problem !== undefined;

  return {
    identity: claimed
      ? {
          Claimed: {
            email:
              certificate.actorEmail.problem === undefined
                ? certificate.actorEmail.value
                : null,
          },
        }
      : "Absent",
    fields: [
      ...fields.filter((field) => field.problem !== null),
      ...fields.filter((field) => field.problem === null),
    ],
  };
}

// An identity an MDM enrolled into the Windows certificate stores.
const windowsCertificate: Certificate = {
  commonName: SUBJECT_CN,
  subject: `O=Example Corp, CN=${SUBJECT_CN}`,
  issuer: "DC=com, DC=example, CN=Example Corp Issuing CA 1",
  actorEmail: present(ACTOR_EMAIL),
  accountId: present("6f3f8a2c-0b74-4f8a-9b1f-1c2d3e4f5a6b"),
  mdmDeviceId: present("9a1c7d4e-5f60-4b28-8c3a-2d5e7f9b0c14"),
  deviceSerial: present("PF2X9K7L"),
  serialNumber: "3a:68:e8:18:bf:83:6b:20:c4:37:16:ec:96:d2:7a:a4",
  notBefore: "Mar 12 09:12:44 2026 +00:00",
  notAfter: present("Jun 14 09:12:44 2028 +00:00"),
  signingAlgorithm: present("SHA256withRSA"),
  fingerprint:
    "90:E4:45:C9:E2:8E:8F:5B:57:D2:30:90:8C:6F:B2:3D:CE:A1:61:CA:96:3E:BF:B2:8E:E7:3D:A9:CF:70:DD:B7",
};

// A certificate the client presents even though two of its claims hold nothing usable: one
// whose value is not an email address, and one the certificate leaves empty.
const invalidAttributeCertificate: Certificate = {
  ...windowsCertificate,
  actorEmail: {
    value: "jane.doe(at)example.com",
    problem: "NotAnEmailAddress",
  },
  accountId: { value: null, problem: "Empty" },
};

// Every screen the client can show, in the states worth eyeballing.
const screens: Record<string, Screen> = {
  "overview-signed-out": { route: "/overview", session: "SignedOut" },
  "overview-loading": { route: "/overview", session: "Loading" },
  "overview-signed-in": {
    route: "/overview",
    session: {
      SignedIn: { account_slug: "example-corp", actor_name: "Jane Doe" },
    },
  },
  "overview-certificate-signed-out": {
    route: "/overview",
    session: "SignedOut",
    x509: loadedCertificate(windowsCertificate),
  },
  "overview-certificate-signed-in": {
    route: "/overview",
    session: {
      SignedIn: { account_slug: "example-corp", actor_name: "Jane Doe" },
    },
    x509: loadedCertificate(windowsCertificate),
  },
  "general-settings": { route: "/general-settings", generalSettings },
  "general-settings-managed": {
    route: "/general-settings",
    generalSettings: {
      ...generalSettings,
      account_slug_is_managed: true,
      connect_on_start_is_managed: true,
    },
  },
  "advanced-settings": { route: "/advanced-settings", advancedSettings },
  "advanced-settings-managed": {
    route: "/advanced-settings",
    advancedSettings: {
      ...advancedSettings,
      api_url_is_managed: true,
      auth_url_is_managed: true,
      log_filter_is_managed: true,
    },
    hover: "Auth Base URL",
  },
  "x509-happy": {
    route: "/x509",
    x509: loadedCertificate(windowsCertificate),
  },
  "x509-invalid-attribute": {
    route: "/x509",
    x509: loadedCertificate(invalidAttributeCertificate),
  },
  "diagnostics-no-logs": { route: "/diagnostics" },
  diagnostics: {
    route: "/diagnostics",
    logCount: { bytes: 3_400_000, files: 12 },
  },
  about: { route: "/about" },
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
  for (const colorScheme of COLOR_SCHEMES) {
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
        if (screen.generalSettings)
          await events.generalSettingsChanged.emit(screen.generalSettings);
        if (screen.advancedSettings)
          await events.advancedSettingsChanged.emit(screen.advancedSettings);
        if (screen.x509) await events.x509CertificateChanged.emit(screen.x509);
        if (screen.logCount) await events.logsRecounted.emit(screen.logCount);
      });

      await settle();

      if (screen.hover) {
        await page.getByLabelText(screen.hover).hover();
        await settle();
      }

      await page.screenshot({
        path: `../screenshots/${name}-${colorScheme}.png`,
      });
    });
  }
}
