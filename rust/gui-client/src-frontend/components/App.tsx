import React, { useEffect, useState } from "react";
import { Navigate, Route, Routes } from "react-router";
import About from "./AboutPage";
import ColorPalette from "./ColorPalettePage";
import DeviceTrustPage from "./DeviceTrustPage";
import Diagnostics from "./DiagnosticsPage";
import GeneralSettingsPage from "./GeneralSettingsPage";
import Overview from "./OverviewPage";
import ReactRouterSidebarItem from "./ReactRouterSidebarItem";
import Titlebar from "./Titlebar";
import {
  commands,
  events,
  FileCount,
  GeneralSettingsViewModel,
  LogFilterViewModel,
  SessionViewModel,
  X509Certificate,
} from "../generated/bindings";

export default function App() {
  const [session, setSession] = useState<SessionViewModel | null>(null);
  const [logCount, setLogCount] = useState<FileCount | null>(null);
  const [generalSettings, setGeneralSettings] =
    useState<GeneralSettingsViewModel | null>(null);
  const [logFilter, setLogFilter] = useState<LogFilterViewModel | null>(null);
  const [deviceTrustCertificate, setDeviceTrustCertificate] =
    useState<X509Certificate | null>();

  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void)[] | null = null;

    void Promise.all([
      events.sessionChanged.listen((event) => {
        console.log("session_changed", { session: event.payload });
        setSession(event.payload);
      }),
      events.generalSettingsChanged.listen((event) => {
        console.log("general_settings_changed", { settings: event.payload });
        setGeneralSettings(event.payload);
      }),
      events.logFilterChanged.listen((event) => {
        console.log("log_filter_changed", { log_filter: event.payload });
        setLogFilter(event.payload);
      }),
      events.logsRecounted.listen((event) => {
        console.log("logs_recounted", { file_count: event.payload });
        setLogCount(event.payload);
      }),
      events.x509CertificateChanged.listen((event) => {
        console.log("x509_certificate_changed", { certificate: event.payload });
        setDeviceTrustCertificate(event.payload);
      }),
    ]).then((newUnlisten) => {
      if (cancelled) {
        newUnlisten.forEach((stopListening) => stopListening());
        return;
      }

      unlisten = newUnlisten;

      // `listen` registers asynchronously. Requesting state any earlier can make
      // the controller's events arrive before their listeners exist.
      void commands.updateState();
    });

    return () => {
      cancelled = true;
      unlisten?.forEach((stopListening) => stopListening());
    };
  }, []);

  const isDev = import.meta.env.DEV;

  return (
    <div className="app-shell">
      <Routes>
        <Route path="/overview" element={<Titlebar title="Firezone" />} />
        <Route
          path="/general-settings"
          element={<Titlebar title="Settings" />}
        />
        <Route
          path="/device-trust"
          element={
            deviceTrustCertificate ? <Titlebar title="Device Trust" /> : null
          }
        />
        <Route path="/diagnostics" element={<Titlebar title="Diagnostics" />} />
        <Route path="/about" element={<Titlebar title="About" />} />
        <Route
          path="/colour-palette"
          element={<Titlebar title="Colour Palette" />}
        />
      </Routes>

      <div className="flex min-h-0 flex-1">
        <aside className="flex w-56 shrink-0 flex-col border-r border-border bg-surface">
          <nav
            aria-label="Client navigation"
            className="flex-1 overflow-y-auto px-2 py-3"
          >
            <ul className="space-y-0.5">
              <li>
                <ReactRouterSidebarItem icon="home" href="/overview">
                  Overview
                </ReactRouterSidebarItem>
              </li>
              <li>
                <ReactRouterSidebarItem
                  icon="settings"
                  href="/general-settings"
                >
                  Settings
                </ReactRouterSidebarItem>
              </li>
              {deviceTrustCertificate && (
                <li>
                  <ReactRouterSidebarItem
                    icon="certificate"
                    href="/device-trust"
                  >
                    Device Trust
                  </ReactRouterSidebarItem>
                </li>
              )}
              <li>
                <ReactRouterSidebarItem icon="database" href="/diagnostics">
                  Diagnostics
                </ReactRouterSidebarItem>
              </li>
              <li>
                <ReactRouterSidebarItem icon="information" href="/about">
                  About
                </ReactRouterSidebarItem>
              </li>
              {isDev && (
                <li className="mt-3 border-t border-border pt-3">
                  <ReactRouterSidebarItem icon="palette" href="/colour-palette">
                    Color Palette
                  </ReactRouterSidebarItem>
                </li>
              )}
            </ul>
          </nav>
        </aside>

        <main className="min-w-0 flex-1 overflow-auto bg-page">
          <Routes>
            <Route
              path="/overview"
              element={
                <Overview
                  session={session}
                  signIn={commands.signIn}
                  signOut={commands.signOut}
                />
              }
            />
            <Route
              path="/general-settings"
              element={
                <GeneralSettingsPage
                  settings={generalSettings}
                  saveSettings={commands.applyClientSettings}
                  resetSettings={commands.resetClientSettings}
                />
              }
            />
            <Route
              path="/device-trust"
              element={
                deviceTrustCertificate === null ? (
                  <Navigate replace to="/overview" />
                ) : deviceTrustCertificate === undefined ? null : (
                  <DeviceTrustPage certificate={deviceTrustCertificate} />
                )
              }
            />
            <Route
              path="/diagnostics"
              element={
                <Diagnostics
                  logCount={logCount}
                  logFilter={logFilter}
                  exportLogs={commands.exportLogs}
                  clearLogs={commands.clearLogs}
                  saveLogFilter={commands.applyLogFilter}
                />
              }
            />
            <Route path="/about" element={<About />} />
            <Route path="/colour-palette" element={<ColorPalette />} />
          </Routes>
        </main>
      </div>
    </div>
  );
}
