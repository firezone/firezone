"use client";
import Link from "next/link";

export function SignUpButton() {
  return (
    <Link href="https://app.firezone.dev/sign_up">
      <button
        type="button"
        className="text-white bg-accent-450 hover:bg-accent-700 font-semibold hover:font-bold tracking-tight rounded duration-0 hover:scale-105 transition transform text-sm px-5 py-2.5 "
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
        className="text-primary-450 bg-white hover:bg-neutral-50 border border-1 border-primary-450 hover:border-2 hover:font-bold font-semibold tracking-tight rounded duration-0 hover:scale-105 transition transform text-sm px-5 py-2.5 "
      >
        Request demo
      </button>
    </Link>
  );
}
