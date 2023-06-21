"use client";
import Link from "next/link";

export default function DeployButton() {
  return (
    <Link href="/docs/deploy">
      <button
        type="button"
        className="text-white font-medium rounded-lg text-sm px-5 py-2.5 focus:outline-none bg-gradient-to-r from-purple-500 via-purple-600 to-purple-700 hover:bg-gradient-to-br focus:ring-4 focus:ring-violet-300"
      >
        Deploy now
      </button>
    </Link>
  );
}
