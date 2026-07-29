import React from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import logo from "../logo.png";

export default function AboutPage() {
  return (
    <div className="flex min-h-full items-center justify-center bg-page p-6">
      <div className="flex w-full max-w-sm flex-col items-center text-center">
        <img src={logo} alt="Firezone Logo" className="mb-6 h-20 w-20" />
        <p className="mb-1 text-body">Version</p>
        <p className="mb-1 text-2xl font-bold text-heading">
          <span>{__APP_VERSION__}</span>
        </p>
        <p className="mb-6 font-mono text-sm text-subtle">
          (<span>{__GIT_VERSION__?.substring(0, 8)}</span>)
        </p>
        <button
          onClick={() =>
            openUrl("https://www.firezone.dev/kb?utm_source=product").catch(
              (e) => console.error("Failed to open documentation URL", e)
            )
          }
          role="link"
          className="rounded px-2 py-1.5 text-sm font-medium text-brand transition-colors hover:bg-brand-muted hover:text-brand-dark"
        >
          Documentation
        </button>
      </div>
    </div>
  );
}
