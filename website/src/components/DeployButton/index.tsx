"use client";
import Link from "next/link";

export default function DeployButton() {
  return (
    <Link href="/docs/deploy">
      <button
        type="button"
        className="text-white font-medium rounded-md text-sm px-5 py-2.5 focus:outline-none bg-gradient-to-r from-accent-500 via-accent-600 to-accent-700 hover:bg-gradient-to-br focus:ring-4 focus:ring-accent-300"
      >
        Deploy now
      </button>
    </Link>
  );
}
