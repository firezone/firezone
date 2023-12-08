"use client";
import Link from "next/link";

export default function RequestAccessButton() {
  return (
    <Link href="/product/early-access">
      <button
        type="button"
        className="text-white font-bold tracking-tight rounded duration-0 hover:scale-105 transition transform shadow-lg text-sm px-5 py-2.5 bg-accent-450 hover:bg-accent-700"
      >
        Request early access
      </button>
    </Link>
  );
}
