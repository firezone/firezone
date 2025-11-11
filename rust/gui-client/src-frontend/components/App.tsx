import {
  Bars3Icon,
  CogIcon,
  DocumentMagnifyingGlassIcon,
  HomeIcon,
  InformationCircleIcon,
  SwatchIcon,
  WrenchScrewdriverIcon,
} from "@heroicons/react/24/solid";
import {
  Sidebar,
  SidebarCollapse,
  SidebarItemGroup,
  SidebarItems,
} from "flowbite-react";
import React, { useEffect, useState } from "react";
import { Route, Routes } from "react-router";
import About from "./AboutPage";
import AdvancedSettingsPage from "./AdvancedSettingsPage";
import ReactRouterSidebarItem from "./ReactRouterSidebarItem";
import ColorPalette from "./ColorPalettePage";
import Diagnostics from "./DiagnosticsPage";
import GeneralSettingsPage from "./GeneralSettingsPage";
import Overview from "./OverviewPage";
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
    <div className="h-screen flex flex-col rounded-lg border border-neutral-300 overflow-hidden">
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
      <div className="flex-1 bg-neutral-50 flex flex-row">
        <Sidebar
          aria-label="Sidebar"
          className="w-52 flex-shrink-0 border-r border-neutral-200"
        >
          <SidebarItems>
            <SidebarItemGroup>
              <ReactRouterSidebarItem icon={HomeIcon} href="/overview">
                Overview
              </ReactRouterSidebarItem>
              <SidebarCollapse label="Settings" open={true} icon={Bars3Icon}>
                <ReactRouterSidebarItem icon={CogIcon} href="/general-settings">
                  General
                </ReactRouterSidebarItem>
                <ReactRouterSidebarItem
                  icon={WrenchScrewdriverIcon}
                  href="/advanced-settings"
                >
                  Advanced
                </ReactRouterSidebarItem>
              </SidebarCollapse>
              <ReactRouterSidebarItem
                icon={DocumentMagnifyingGlassIcon}
                href="/diagnostics"
              >
                Diagnostics
              </ReactRouterSidebarItem>
              <ReactRouterSidebarItem
                icon={InformationCircleIcon}
                href="/about"
              >
                About
              </ReactRouterSidebarItem>
            </SidebarItemGroup>
            {isDev && (
              <SidebarItemGroup>
                <ReactRouterSidebarItem
                  icon={SwatchIcon}
                  href="/colour-palette"
                >
                  Color Palette
                </ReactRouterSidebarItem>
              </SidebarItemGroup>
            )}
          </SidebarItems>
        </Sidebar>
        <main className="flex-grow overflow-auto">
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
