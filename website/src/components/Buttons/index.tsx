"use client";
import Link from "next/link";

export function SignUpButton() {
  return (
    <Link href="https://app.firezone.dev/sign_up">
      <button
        type="button"
        className="text-xs px-3 py-1.5 lg:text-sm lg:px-5 lg:py-2.5 text-primary-450 bg-white hover:bg-neutral-50 border border-1 border-primary-450 hover:border-2 hover:font-bold font-semibold tracking-tight rounded duration-0 hover:scale-105 transition transform"
      >
        Sign up
      </button>
    </Link>
  );
}

export function RequestDemoButton() {
  return (
    <Link href="/contact/sales">
      <button
        type="button"
        className="text-xs px-3 py-1.5 lg:text-sm lg:px-5 lg:py-2.5 text-white bg-primary-450 font-semibold hover:font-bold tracking-tight rounded duration-0 hover:scale-105 transition transform"
      >
        Request demo
      </button>
    </Link>
  );
}
