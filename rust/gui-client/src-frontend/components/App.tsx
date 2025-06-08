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
import { FileCount, LOGS_RECOUNTED } from "../generated/FileCount";
import { Session } from "../generated/Session";
import About from "./AboutPage";
import AdvancedSettingsPage from "./AdvancedSettingsPage";
import ColorPalette from "./ColorPalettePage";
import Diagnostics from "./DiagnosticsPage";
import GeneralSettingsPage from "./GeneralSettingsPage";
import Overview from "./OverviewPage";
import {
  ADVANCED_SETTINGS_CHANGED,
  GENERAL_SETTINGS_CHANGED,
  GeneralSettingsViewModel,
} from "../generated/GeneralSettingsViewModel";
import { ABOUT, GENERAL_SETTINGS, OVERVIEW } from "../generated/Routes";

export default function App() {
  let [session, setSession] = useState<Session | null>(null);
  let [logCount, setLogCount] = useState<FileCount | null>(null);
  let [generalSettings, setGeneralSettings] =
    useState<GeneralSettingsViewModel | null>(null);
  let [advancedSettings, setAdvancedSettings] =
    useState<AdvancedSettingsViewModel | null>(null);

  useEffect(() => {
    const signedInUnlisten = listen<Session>("signed_in", (e) => {
      let session = e.payload;

      console.log("signed_in", { session });
      setSession(session);
    });
    const signedOutUnlisten = listen<void>("signed_out", (_e) => {
      console.log("signed_out");
      setSession(null);
    });
    const generalSettingsChangedUnlisten = listen<GeneralSettingsViewModel>(
      GENERAL_SETTINGS_CHANGED,
      (e) => {
        let generalSettings = e.payload;

        console.log(`${GENERAL_SETTINGS_CHANGED}`, {
          settings: generalSettings,
        });
        setGeneralSettings(generalSettings);
      }
    );
    const advancedSettingsChangedUnlisten = listen<AdvancedSettingsViewModel>(
      ADVANCED_SETTINGS_CHANGED,
      (e) => {
        let advancedSettings = e.payload;

        console.log(`${ADVANCED_SETTINGS_CHANGED}`, {
          settings: advancedSettings,
        });
        setAdvancedSettings(advancedSettings);
      }
    );
    const logsRecountedUnlisten = listen<FileCount>(LOGS_RECOUNTED, (e) => {
      let file_count = e.payload;

      console.log(`${LOGS_RECOUNTED}`, { file_count });
      setLogCount(file_count);
    });

    invoke<void>("update_state"); // Let the backend know that we (re)-initialised

    return () => {
      signedInUnlisten.then((unlistenFn) => unlistenFn());
      signedOutUnlisten.then((unlistenFn) => unlistenFn());
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
            <NavLink to={`/${OVERVIEW}`}>
              {({ isActive }) => (
                <SidebarItem active={isActive} icon={HomeIcon} as="div">
                  Overview
                </SidebarItem>
              )}
            </NavLink>
            <SidebarCollapse label="Settings" open={true} icon={Bars3Icon}>
              <NavLink to={`/${GENERAL_SETTINGS}`}>
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
            <NavLink to={`/${ABOUT}`}>
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
