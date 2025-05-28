import React from "react";
import logo from "../logo.png";

interface AboutPageProps {
  appVersion: string | null;
  gitVersion: string | null;
}

export default function AboutPage({ appVersion, gitVersion }: AboutPageProps) {
  return (
    <div className="w-full h-full max-w-sm flex flex-col justify-center items-center mx-auto">
      <img src={logo} alt="Firezone Logo" className="w-20 h-20 mb-6" />
      <p className="text-neutral-600 mb-1">Version</p>
      <p className="text-2xl font-bold mb-1">
        <span>{appVersion}</span>
      </p>
      <p className="text-neutral-400 text-sm mb-6">
        (<span>{gitVersion?.substring(0, 8)}</span>)
      </p>
      <a
        href="https://docs.firezone.dev"
        target="_blank"
        rel="noopener noreferrer"
        className="text-accent-450 hover:underline text-sm"
      >
        Documentation
      </a>
    </div>
  );
}
