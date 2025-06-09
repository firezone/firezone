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
  SidebarItem,
  SidebarItemGroup,
  SidebarItems,
} from "flowbite-react";
import React, { useEffect, useState } from "react";
import { NavLink, Route, Routes } from "react-router";
import { AdvancedSettingsViewModel } from "../generated/AdvancedSettingsViewModel";
import { FileCount } from "../generated/FileCount";
import { SessionViewModel } from "../generated/SessionViewModel";
import About from "./AboutPage";
import AdvancedSettingsPage from "./AdvancedSettingsPage";
import ColorPalette from "./ColorPalettePage";
import Diagnostics from "./DiagnosticsPage";
import GeneralSettingsPage from "./GeneralSettingsPage";
import Overview from "./OverviewPage";
import { GeneralSettingsViewModel } from "../generated/GeneralSettingsViewModel";

export default function App() {
  let [session, setSession] = useState<SessionViewModel | null>(null);
  let [logCount, setLogCount] = useState<FileCount | null>(null);
  let [generalSettings, setGeneralSettings] =
    useState<GeneralSettingsViewModel | null>(null);
  let [advancedSettings, setAdvancedSettings] =
    useState<AdvancedSettingsViewModel | null>(null);

  useEffect(() => {
    const sessionChanged = listen<SessionViewModel>("session_changed", (e) => {
      let session = e.payload;

      console.log("session_changed", { session });
      setSession(session);
    });
    const generalSettingsChangedUnlisten = listen<GeneralSettingsViewModel>(
      "general_settings_changed",
      (e) => {
        let generalSettings = e.payload;

        console.log("general_settings_changed", { settings: generalSettings });
        setGeneralSettings(generalSettings);
      }
    );
    const advancedSettingsChangedUnlisten = listen<AdvancedSettingsViewModel>(
      "advanced_settings_changed",
      (e) => {
        let advancedSettings = e.payload;

        console.log("advanced_settings_changed", {
          settings: advancedSettings,
        });
        setAdvancedSettings(advancedSettings);
      }
    );
    const logsRecountedUnlisten = listen<FileCount>("logs_recounted", (e) => {
      let file_count = e.payload;

      console.log("logs_recounted", { file_count });
      setLogCount(file_count);
    });

    invoke<void>("update_state"); // Let the backend know that we (re)-initialised

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
            <NavLink to="/overview">
              {({ isActive }) => (
                <SidebarItem active={isActive} icon={HomeIcon} as="div">
                  Overview
                </SidebarItem>
              )}
            </NavLink>
            <SidebarCollapse label="Settings" open={true} icon={Bars3Icon}>
              <NavLink to="/general-settings">
                {({ isActive }) => (
                  <SidebarItem active={isActive} icon={CogIcon} as="div">
                    General
                  </SidebarItem>
                )}
              </NavLink>
              <NavLink to="/advanced-settings">
                {({ isActive }) => (
                  <SidebarItem
                    active={isActive}
                    icon={WrenchScrewdriverIcon}
                    as="div"
                  >
                    Advanced
                  </SidebarItem>
                )}
              </NavLink>
            </SidebarCollapse>
            <NavLink to="/diagnostics">
              {({ isActive }) => (
                <SidebarItem
                  active={isActive}
                  icon={DocumentMagnifyingGlassIcon}
                  as="div"
                >
                  Diagnostics
                </SidebarItem>
              )}
            </NavLink>
            <NavLink to="/about">
              {({ isActive }) => (
                <SidebarItem
                  active={isActive}
                  icon={InformationCircleIcon}
                  as="div"
                >
                  About
                </SidebarItem>
              )}
            </NavLink>
          </SidebarItemGroup>
          {isDev && (
            <SidebarItemGroup>
              <NavLink to="/colour-palette">
                {({ isActive }) => (
                  <SidebarItem active={isActive} icon={SwatchIcon} as="div">
                    Color Palette
                  </SidebarItem>
                )}
              </NavLink>
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
                  let logCount = await invoke<FileCount>("count_logs");

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
