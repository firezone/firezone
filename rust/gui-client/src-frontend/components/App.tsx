import {
  CogIcon,
  DocumentMagnifyingGlassIcon,
  HomeIcon,
  InformationCircleIcon,
  SwatchIcon,
} from "@heroicons/react/24/solid";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import {
  Sidebar,
  SidebarItem,
  SidebarItemGroup,
  SidebarItems,
} from "flowbite-react";
import React, { useEffect, useState } from "react";
import { NavLink, Route, Routes } from "react-router";
import { AdvancedSettingsViewModel as Settings } from "../generated/AdvancedSettingsViewModel";
import { FileCount } from "../generated/FileCount";
import { Session } from "../generated/Session";
import initSentry from "../initSentry";
import About from "./AboutPage";
import ColorPalette from "./ColorPalettePage";
import Diagnostics from "./DiagnosticsPage";
import Overview from "./OverviewPage";
import SettingsPage from "./SettingsPage";

export default function App() {
  let [session, setSession] = useState<Session | null>(null);
  let [logCount, setLogCount] = useState<FileCount | null>(null);
  let [settings, setSettings] = useState<Settings | null>(null);

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
    const settingsChangedUnlisten = listen<Settings>(
      "settings_changed",
      (e) => {
        let settings = e.payload;

        console.log("settings_changed", { settings });
        setSettings(settings);
        initSentry(settings.api_url);
      }
    );
    const logsRecountedUnlisten = listen<FileCount>("logs_recounted", (e) => {
      let file_count = e.payload;

      console.log("logs_recounted", { file_count });
      setLogCount(file_count);
    });

    invoke<void>("update_state"); // Let the backend know that we (re)-initialised

    return () => {
      signedInUnlisten.then((unlistenFn) => unlistenFn());
      signedOutUnlisten.then((unlistenFn) => unlistenFn());
      settingsChangedUnlisten.then((unlistenFn) => unlistenFn());
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
            <NavLink to="/settings">
              {({ isActive }) => (
                <SidebarItem active={isActive} icon={CogIcon} as="div">
                  Settings
                </SidebarItem>
              )}
            </NavLink>
            <NavLink to="/diagnostics">
              {({ isActive }) => (
                <SidebarItem active={isActive} icon={DocumentMagnifyingGlassIcon} as="div">
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
            path="/settings"
            element={
              <SettingsPage
                settings={settings}
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
