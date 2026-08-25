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
  X509DetailSection,
  X509FieldValue,
  X509Status,
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
  /// What the keystore holds, as the typed problems the screen turns into sentences.
  x509?: X509Status;
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

// What the keystore backends title the certificate they picked and one they skipped.
const CERTIFICATE = "Certificate";
const UNUSED_CERTIFICATE = "Unused Certificate";

// One certificate as the diagnostics describe it. Every value is fixed: a field read from the
// clock, or from a certificate minted at test time, would put a new image in the gallery on
// every run.
interface Certificate {
  commonName: string;
  subject: string;
  issuer: string;
  actorEmail: X509FieldValue;
  accountId: X509FieldValue;
  mdmDeviceId: X509FieldValue;
  deviceSerial: X509FieldValue;
  serialNumber: string;
  notBefore: string;
  notAfter: string;
  signingAlgorithm: string;
  fingerprint: string;
}

// The rows in the order `x509_claims::ParsedCertificate::detail_fields` builds them.
function certificateSection(
  title: string,
  certificate: Certificate
): X509DetailSection {
  return {
    title,
    fields: [
      { label: "Common Name", value: { Present: certificate.commonName } },
      { label: "Subject", value: { Present: certificate.subject } },
      { label: "Issuer", value: { Present: certificate.issuer } },
      { label: "Actor Email", value: certificate.actorEmail },
      { label: "Account ID", value: certificate.accountId },
      { label: "MDM Device ID", value: certificate.mdmDeviceId },
      { label: "Device Serial", value: certificate.deviceSerial },
      { label: "Serial Number", value: { Present: certificate.serialNumber } },
      { label: "Not Before", value: { Present: certificate.notBefore } },
      { label: "Not After", value: { Present: certificate.notAfter } },
      {
        label: "Signing Algorithm",
        value: { Present: certificate.signingAlgorithm },
      },
      {
        label: "SHA-256 Fingerprint",
        value: { Present: certificate.fingerprint },
      },
    ],
  };
}

// An identity an MDM enrolled into the Windows certificate stores.
const windowsCertificate: Certificate = {
  commonName: SUBJECT_CN,
  subject: `O=Acme Corp, CN=${SUBJECT_CN}`,
  issuer: "DC=example, DC=acme, CN=Acme Corp Issuing CA 1",
  actorEmail: { Present: "jane.doe@acme.example" },
  accountId: { Present: "6f3f8a2c-0b74-4f8a-9b1f-1c2d3e4f5a6b" },
  mdmDeviceId: { Present: "9a1c7d4e-5f60-4b28-8c3a-2d5e7f9b0c14" },
  deviceSerial: { Present: "PF2X9K7L" },
  serialNumber: "3a:68:e8:18:bf:83:6b:20:c4:37:16:ec:96:d2:7a:a4",
  notBefore: "Mar 12 09:12:44 2026 +00:00",
  notAfter: "Jun 14 09:12:44 2028 +00:00",
  signingAlgorithm: "SHA256withRSA",
  fingerprint:
    "90:E4:45:C9:E2:8E:8F:5B:57:D2:30:90:8C:6F:B2:3D:CE:A1:61:CA:96:3E:BF:B2:8E:E7:3D:A9:CF:70:DD:B7",
};

// An identity on a PKCS#11 token, which attests the device without naming an actor.
const linuxCertificate: Certificate = {
  commonName: SUBJECT_CN,
  subject: `O=Acme Corp, CN=${SUBJECT_CN}`,
  issuer: "O=Acme Corp, CN=Acme Corp Device CA",
  actorEmail: { Present: "ravi.patel@acme.example" },
  accountId: { Present: "6f3f8a2c-0b74-4f8a-9b1f-1c2d3e4f5a6b" },
  mdmDeviceId: "Absent",
  deviceSerial: { Present: "7QK4M3J" },
  serialNumber: "ee:0d:bc:83:e7:cc:35:bc:2f:91:94:b1:e2:d2:95:f4",
  notBefore: "Nov 20 14:05:31 2025 +00:00",
  notAfter: "Feb 23 14:05:31 2028 +00:00",
  signingAlgorithm: "SHA256withECDSA",
  fingerprint:
    "29:19:1D:E9:31:EB:64:B5:2E:2D:64:44:FB:E7:E5:C0:EF:82:EF:8C:1C:B3:75:6A:77:A1:E5:AE:8C:F1:73:31",
};

// A certificate the client presents even though one of its claims will not be attested.
const invalidAttributeCertificate: Certificate = {
  ...windowsCertificate,
  actorEmail: { Rejected: "NotAnEmailAddress" },
};

const expiredCertificate: Certificate = {
  ...windowsCertificate,
  serialNumber: "7d:f2:02:1f:e6:58:05:32:af:9c:0f:07:46:91:15:24",
  notBefore: "Feb 14 08:30:00 2023 +00:00",
  notAfter: "May 19 08:30:00 2025 +00:00",
  fingerprint:
    "DA:A5:4F:C1:B7:D1:F0:DA:C3:AC:A5:F1:07:16:4E:DA:AE:63:15:BC:CB:7E:59:AA:FC:1D:E3:C0:63:C2:3C:AC",
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
  "x509-empty-windows": {
    route: "/x509",
    x509: {
      problems: [{ NoWindowsCertificate: { subject_cn: SUBJECT_CN } }],
      sections: [],
    },
  },
  "x509-empty-linux": {
    route: "/x509",
    x509: {
      problems: [{ NoPkcs11Certificate: { subject_cn: SUBJECT_CN } }],
      sections: [],
    },
  },
  "x509-happy-windows": {
    route: "/x509",
    x509: {
      problems: [],
      sections: [certificateSection(CERTIFICATE, windowsCertificate)],
    },
  },
  "x509-happy-linux": {
    route: "/x509",
    x509: {
      problems: [],
      sections: [certificateSection(CERTIFICATE, linuxCertificate)],
    },
  },
  "x509-missing-package-linux": {
    route: "/x509",
    x509: {
      problems: [{ MissingPackage: { package: "P11Kit" } }],
      sections: [],
    },
  },
  "x509-invalid-attribute": {
    route: "/x509",
    x509: {
      problems: [],
      sections: [certificateSection(CERTIFICATE, invalidAttributeCertificate)],
    },
  },
  // Nothing was picked, so the certificate that was found is an unused one.
  "x509-unusable": {
    route: "/x509",
    x509: {
      problems: [
        {
          NoUsableWindowsCertificate: {
            certificates: [
              {
                fingerprint: expiredCertificate.fingerprint,
                cause: { FailsRules: { reasons: ["OutsideValidityPeriod"] } },
              },
            ],
          },
        },
      ],
      sections: [certificateSection(UNUSED_CERTIFICATE, expiredCertificate)],
    },
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
        if (screen.x509) await events.x509StatusChanged.emit(screen.x509);
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
