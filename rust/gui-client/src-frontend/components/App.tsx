import {
  Bars3Icon,
  CogIcon,
  DocumentMagnifyingGlassIcon,
  HomeIcon,
  InformationCircleIcon,
  SwatchIcon,
  WrenchScrewdriverIcon,
} from "@heroicons/react/24/solid";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import {
  Sidebar,
  SidebarCollapse,
  SidebarItemGroup,
  SidebarItems,
} from "flowbite-react";
import React, { useEffect, useState } from "react";
import { Route, Routes } from "react-router";
import { AdvancedSettingsViewModel } from "../generated/AdvancedSettingsViewModel";
import { FileCount } from "../generated/FileCount";
import { SessionViewModel } from "../generated/SessionViewModel";
import About from "./AboutPage";
import AdvancedSettingsPage from "./AdvancedSettingsPage";
import ReactRouterSidebarItem from "./ReactRouterSidebarItem";
import ColorPalette from "./ColorPalettePage";
import Diagnostics from "./DiagnosticsPage";
import GeneralSettingsPage from "./GeneralSettingsPage";
import Overview from "./OverviewPage";
import { GeneralSettingsViewModel } from "../generated/GeneralSettingsViewModel";

export default function App() {
  const [session, setSession] = useState<SessionViewModel | null>(null);
  const [logCount, setLogCount] = useState<FileCount | null>(null);
  const [generalSettings, setGeneralSettings] =
    useState<GeneralSettingsViewModel | null>(null);
  const [advancedSettings, setAdvancedSettings] =
    useState<AdvancedSettingsViewModel | null>(null);

  useEffect(() => {
    const sessionChanged = listen<SessionViewModel>("session_changed", (e) => {
      const session = e.payload;

      console.log("session_changed", { session });
      setSession(session);
    });
    const generalSettingsChangedUnlisten = listen<GeneralSettingsViewModel>(
      "general_settings_changed",
      (e) => {
        const generalSettings = e.payload;

        console.log("general_settings_changed", { settings: generalSettings });
        setGeneralSettings(generalSettings);
      },
    );
    const advancedSettingsChangedUnlisten = listen<AdvancedSettingsViewModel>(
      "advanced_settings_changed",
      (e) => {
        const advancedSettings = e.payload;

        console.log("advanced_settings_changed", {
          settings: advancedSettings,
        });
        setAdvancedSettings(advancedSettings);
      },
    );
    const logsRecountedUnlisten = listen<FileCount>("logs_recounted", (e) => {
      const file_count = e.payload;

      console.log("logs_recounted", { file_count });
      setLogCount(file_count);
    });

    invoke("update_state"); // Let the backend know that we (re)-initialised

    return () => {
      sessionChanged.then((unlistenFn) => unlistenFn());
      generalSettingsChangedUnlisten.then((unlistenFn) => unlistenFn());
      advancedSettingsChangedUnlisten.then((unlistenFn) => unlistenFn());
      logsRecountedUnlisten.then((unlistenFn) => unlistenFn());
    };
  }, []);

  const isDev = import.meta.env.DEV;

  return (
    <div className="h-screen bg-neutral-50 flex flex-row">
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
            <ReactRouterSidebarItem icon={InformationCircleIcon} href="/about">
              About
            </ReactRouterSidebarItem>
          </SidebarItemGroup>
          {isDev && (
            <SidebarItemGroup>
              <ReactRouterSidebarItem icon={SwatchIcon} href="/colour-palette">
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
                signIn={() => invoke("sign_in")}
                signOut={() => invoke("sign_out")}
              />
            }
          />
          <Route
            path="/general-settings"
            element={
              <GeneralSettingsPage
                settings={generalSettings}
                saveSettings={(settings) =>
                  invoke("apply_general_settings", { settings })
                }
                resetSettings={() => invoke("reset_general_settings")}
              />
            }
          />
          <Route
            path="/advanced-settings"
            element={
              <AdvancedSettingsPage
                settings={advancedSettings}
                saveSettings={(settings) =>
                  invoke("apply_advanced_settings", { settings })
                }
                resetSettings={() => invoke("reset_advanced_settings")}
              />
            }
          />
          <Route
            path="/diagnostics"
            element={
              <Diagnostics
                logCount={logCount}
                exportLogs={() => invoke("export_logs")}
                clearLogs={async () => {
                  await invoke("clear_logs");
                  const logCount = await invoke<FileCount>("count_logs");

                  setLogCount(logCount);
                }}
              />
            }
          />
          <Route path="/about" element={<About />} />
          <Route path="/colour-palette" element={<ColorPalette />} />
        </Routes>
      </main>
    </div>
  );
}
