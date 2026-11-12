import { openUrl } from "@tauri-apps/plugin-opener";
import React, { useEffect, useState } from "react";
import { DeveloperSettings } from "../generated/bindings";
import logo from "../logo.png";
import Button from "./Button";
import SettingRow from "./SettingRow";

const DEVELOPER_SETTINGS_UNLOCK_CLICKS = 7;

interface Props {
  loadDeveloperSettings: () => Promise<DeveloperSettings>;
  saveDeveloperSettings: (settings: DeveloperSettings) => void;
  resetConnlib: () => void;
}

export default function AboutPage({
  loadDeveloperSettings,
  saveDeveloperSettings,
  resetConnlib,
}: Props) {
  const [unlocked, setUnlocked] = useState(false);
  const [logoClicks, setLogoClicks] = useState(0);

  useEffect(() => {
    void loadDeveloperSettings().then((settings) =>
      setUnlocked(settings.unlocked)
    );
  }, [loadDeveloperSettings]);

  const saveUnlocked = (unlocked: boolean) => {
    setUnlocked(unlocked);
    setLogoClicks(0);
    saveDeveloperSettings({ unlocked });
  };

  const clickLogo = () => {
    const clicks = logoClicks + 1;
    setLogoClicks(clicks);
    if (clicks === DEVELOPER_SETTINGS_UNLOCK_CLICKS) saveUnlocked(true);
  };

  const openDocumentation = () => {
    openUrl("https://www.firezone.dev/kb?utm_source=product").catch((error) =>
      console.error("Failed to open documentation URL", error)
    );
  };

  const openCommit = () => {
    openUrl(
      `https://github.com/firezone/firezone/commit/${__GIT_VERSION__}`
    ).catch((error) => console.error("Failed to open commit URL", error));
  };

  return (
    <div className="flex min-h-full items-center justify-center bg-page p-6">
      <div className="flex w-full max-w-sm flex-col items-center text-center">
        <button className="mb-6" onClick={clickLogo} type="button">
          <img alt="Firezone Logo" className="h-20 w-20" src={logo} />
        </button>
        <p className="mb-1 text-body">Version</p>
        <p className="mb-6 text-lg font-bold text-heading">
          {__APP_VERSION__} (
          <button
            className="font-mono text-brand underline hover:text-brand-dark"
            onClick={openCommit}
            role="link"
            type="button"
          >
            {__GIT_VERSION__.substring(0, 8)}
          </button>
          )
        </p>
        <button
          className="rounded px-2 py-1.5 text-sm font-medium text-brand transition-colors hover:bg-brand-muted hover:text-brand-dark"
          onClick={openDocumentation}
          role="link"
          type="button"
        >
          Documentation
        </button>
        {unlocked && (
          <section className="mt-6 w-full text-left">
            <h2 className="form-label">Developer settings</h2>
            <div className="panel divide-y divide-border">
              <SettingRow label="Reset connlib">
                <Button onClick={resetConnlib} type="button">
                  Reset
                </Button>
              </SettingRow>
              <SettingRow label="Hide developer settings">
                <Button onClick={() => saveUnlocked(false)} type="button">
                  Hide
                </Button>
              </SettingRow>
            </div>
          </section>
        )}
      </div>
    </div>
  );
}
