import { openUrl } from "@tauri-apps/plugin-opener";
import React, { useState } from "react";
import logo from "../logo.png";

const DEVELOPER_SETTINGS_UNLOCK_CLICKS = 7;

interface Props {
  unlockDeveloperSettings: () => void;
}

export default function AboutPage({ unlockDeveloperSettings }: Props) {
  const [logoClicks, setLogoClicks] = useState(0);

  const clickLogo = () => {
    const clicks = logoClicks + 1;
    setLogoClicks(clicks);
    if (clicks === DEVELOPER_SETTINGS_UNLOCK_CLICKS) unlockDeveloperSettings();
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
      </div>
    </div>
  );
}
