import React, { useEffect, useState } from "react";
import { Route, Routes } from "react-router";
import About from "./AboutPage";
import AdvancedSettingsPage from "./AdvancedSettingsPage";
import ColorPalette from "./ColorPalettePage";
import Diagnostics from "./DiagnosticsPage";
import GeneralSettingsPage from "./GeneralSettingsPage";
import Overview from "./OverviewPage";
import ReactRouterSidebarItem from "./ReactRouterSidebarItem";
import RemixIcon from "./RemixIcon";
import Titlebar from "./Titlebar";
import X509Page from "./X509Page";
import {
  AdvancedSettingsViewModel,
  commands,
  events,
  FileCount,
  GeneralSettingsViewModel,
  SessionViewModel,
  X509Status,
} from "../generated/bindings";

export default function App() {
  const [session, setSession] = useState<SessionViewModel | null>(null);
  const [logCount, setLogCount] = useState<FileCount | null>(null);
  const [generalSettings, setGeneralSettings] =
    useState<GeneralSettingsViewModel | null>(null);
  const [advancedSettings, setAdvancedSettings] =
    useState<AdvancedSettingsViewModel | null>(null);
  const [x509Status, setX509Status] = useState<X509Status | null>(null);
  const [settingsOpen, setSettingsOpen] = useState(true);

  useEffect(() => {
    const sessionChangedUnlisten = events.sessionChanged.listen((event) => {
      console.log("session_changed", { session: event.payload });
      setSession(event.payload);
    });
    const generalSettingsChangedUnlisten = events.generalSettingsChanged.listen(
      (event) => {
        console.log("general_settings_changed", { settings: event.payload });
        setGeneralSettings(event.payload);
      }
    );
    const advancedSettingsChangedUnlisten =
      events.advancedSettingsChanged.listen((event) => {
        console.log("advanced_settings_changed", {
          settings: event.payload,
        });
        setAdvancedSettings(event.payload);
      });
    const logsRecountedUnlisten = events.logsRecounted.listen((event) => {
      console.log("logs_recounted", { file_count: event.payload });
      setLogCount(event.payload);
    });
    const x509StatusChangedUnlisten = events.x509StatusChanged.listen(
      (event) => {
        console.log("x509_status_changed", { status: event.payload });
        setX509Status(event.payload);
      }
    );

    commands.updateState();

    return () => {
      sessionChangedUnlisten.then((unlisten) => unlisten());
      generalSettingsChangedUnlisten.then((unlisten) => unlisten());
      advancedSettingsChangedUnlisten.then((unlisten) => unlisten());
      logsRecountedUnlisten.then((unlisten) => unlisten());
      x509StatusChangedUnlisten.then((unlisten) => unlisten());
    };
  }, []);

  const isDev = import.meta.env.DEV;

  return (
    <div className="app-shell">
      <Routes>
        <Route path="/overview" element={<Titlebar title="Firezone" />} />
        <Route
          path="/general-settings"
          element={<Titlebar title="General Settings" />}
        />
        <Route
          path="/advanced-settings"
          element={<Titlebar title="Advanced Settings" />}
        />
        <Route
          path="/x509"
          element={<Titlebar title="X.509 Device Identity" />}
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
                <button
                  aria-expanded={settingsOpen}
                  className="nav-item w-full"
                  onClick={() => setSettingsOpen((open) => !open)}
                  type="button"
                >
                  <RemixIcon className="h-4 w-4" name="settings" />
                  <span className="flex-1 text-left">Settings</span>
                  <RemixIcon
                    className={`h-3.5 w-3.5 transition-transform ${
                      settingsOpen ? "rotate-180" : ""
                    }`}
                    name="arrow-down"
                  />
                </button>
                {settingsOpen && (
                  <ul className="mt-0.5 space-y-0.5 pl-4">
                    <li>
                      <ReactRouterSidebarItem
                        icon="settings"
                        href="/general-settings"
                      >
                        General
                      </ReactRouterSidebarItem>
                    </li>
                    <li>
                      <ReactRouterSidebarItem
                        icon="equalizer"
                        href="/advanced-settings"
                      >
                        Advanced
                      </ReactRouterSidebarItem>
                    </li>
                  </ul>
                )}
              </li>
              <li>
                <ReactRouterSidebarItem icon="certificate" href="/x509">
                  X.509 Identity
                </ReactRouterSidebarItem>
              </li>
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
                  saveSettings={commands.applyGeneralSettings}
                  resetSettings={commands.resetGeneralSettings}
                />
              }
            />
            <Route
              path="/advanced-settings"
              element={
                <AdvancedSettingsPage
                  settings={advancedSettings}
                  saveSettings={commands.applyAdvancedSettings}
                  resetSettings={commands.resetAdvancedSettings}
                />
              }
            />
            <Route path="/x509" element={<X509Page status={x509Status} />} />
            <Route
              path="/diagnostics"
              element={
                <Diagnostics
                  logCount={logCount}
                  exportLogs={commands.exportLogs}
                  clearLogs={commands.clearLogs}
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
