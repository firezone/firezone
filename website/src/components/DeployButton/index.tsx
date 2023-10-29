"use client";
import Link from "next/link";

export default function DeployButton() {
  return (
    <Link href="/docs/deploy">
      <button
        type="button"
        className="text-white font-bold tracking-tight rounded duration-0 hover:scale-105 transition transform shadow-lg text-sm px-5 py-2.5 bg-gradient-to-br from-accent-700 to-accent-600"
      >
        Deploy now
      </button>
    </Link>
  );
}
