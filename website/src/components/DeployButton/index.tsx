"use client";
import Link from "next/link";

export default function DeployButton() {
  return (
    <Link href="/docs/deploy">
      <button
        type="button"
        className="focus:outline-none text-white bg-gradient-to-r from-purple-500 via-purple-600 to-purple-700 hover:bg-gradient-to-br focus:ring-4 focus:ring-violet-300 font-medium rounded-lg text-sm px-5 py-2.5 dark:bg-violet-600 dark:hover:bg-violet-700 dark:focus:ring-violet-900"
      >
        Deploy Now
      </button>
    </Link>
  );
}
