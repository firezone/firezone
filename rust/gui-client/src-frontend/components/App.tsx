import React, { useEffect, useState } from "react";
import { Route, Routes } from "react-router";
import About from "./AboutPage";
import AdvancedSettingsPage from "./AdvancedSettingsPage";
import ReactRouterSidebarItem from "./ReactRouterSidebarItem";
import ColorPalette from "./ColorPalettePage";
import Diagnostics from "./DiagnosticsPage";
import GeneralSettingsPage from "./GeneralSettingsPage";
import Overview from "./OverviewPage";
import RemixIcon from "./RemixIcon";
import {
  AdvancedSettingsViewModel,
  commands,
  events,
  FileCount,
  GeneralSettingsViewModel,
  SessionViewModel,
} from "../generated/bindings";
import Titlebar from "./Titlebar";

export default function App() {
  const [session, setSession] = useState<SessionViewModel | null>(null);
  const [logCount, setLogCount] = useState<FileCount | null>(null);
  const [generalSettings, setGeneralSettings] =
    useState<GeneralSettingsViewModel | null>(null);
  const [advancedSettings, setAdvancedSettings] =
    useState<AdvancedSettingsViewModel | null>(null);
  const [settingsOpen, setSettingsOpen] = useState(true);

  useEffect(() => {
    const sessionChangedUnlisten = events.sessionChanged.listen((e) => {
      const session = e.payload;

      console.log("session_changed", { session });
      setSession(session);
    });
    const generalSettingsChangedUnlisten = events.generalSettingsChanged.listen(
      (e) => {
        const generalSettings = e.payload;

        console.log("general_settings_changed", { settings: generalSettings });
        setGeneralSettings(generalSettings);
      }
    );
    const advancedSettingsChangedUnlisten =
      events.advancedSettingsChanged.listen((e) => {
        const advancedSettings = e.payload;

        console.log("advanced_settings_changed", {
          settings: advancedSettings,
        });
        setAdvancedSettings(advancedSettings);
      });
    const logsRecountedUnlisten = events.logsRecounted.listen((e) => {
      const file_count = e.payload;

      console.log("logs_recounted", { file_count });
      setLogCount(file_count);
    });

    commands.updateState(); // Let the backend know that we (re)-initialised

    return () => {
      sessionChangedUnlisten.then((unlistenFn) => unlistenFn());
      generalSettingsChangedUnlisten.then((unlistenFn) => unlistenFn());
      advancedSettingsChangedUnlisten.then((unlistenFn) => unlistenFn());
      logsRecountedUnlisten.then((unlistenFn) => unlistenFn());
    };
  }, []);

  const isDev = import.meta.env.DEV;

  return (
    <div className="app-shell">
      <Routes>
        <Route path="/overview" element={<Titlebar title={"Firezone"} />} />
        <Route
          path="/general-settings"
          element={<Titlebar title={"General Settings"} />}
        />
        <Route
          path="/advanced-settings"
          element={<Titlebar title={"Advanced Settings"} />}
        />
        <Route
          path="/diagnostics"
          element={<Titlebar title={"Diagnostics"} />}
        />
        <Route path="/about" element={<Titlebar title={"About"} />} />
        <Route
          path="/colour-palette"
          element={<Titlebar title={"Colour Palette"} />}
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
