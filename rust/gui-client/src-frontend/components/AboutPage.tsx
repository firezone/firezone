import { openUrl } from "@tauri-apps/plugin-opener";
import React from "react";
import logo from "../logo.png";

export default function AboutPage() {
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
        <img alt="Firezone Logo" className="mb-6 h-20 w-20" src={logo} />
        <p className="mb-1 text-body">Version</p>
        <p className="mb-1 text-2xl font-bold text-heading">
          <span>{__APP_VERSION__}</span>
        </p>
        <p className="mb-6 font-mono text-sm text-subtle">
          <button
            className="hover:text-brand hover:underline"
            onClick={openCommit}
            role="link"
            type="button"
          >
            {__GIT_VERSION__.substring(0, 8)} (GitHub)
          </button>
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
