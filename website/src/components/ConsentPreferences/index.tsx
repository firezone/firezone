"use client";
import Link from "next/link";

export default function ConsentPreferences() {
  return (
    <Link
      id="termly-consent-preferences"
      href="#"
      className="hover:underline"
      onClick={() => {
        (window as any).displayPreferenceModal();
        return false;
      }}
    >
      cookies
    </Link>
  );
}
