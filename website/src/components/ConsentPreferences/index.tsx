"use client";
import Link from "next/link";

export default function ConsentPreferences({
  className,
}: {
  className?: string;
}) {
  return (
    <Link
      id="termly-consent-preferences"
      href="#"
      className={className}
      onClick={() => {
        (window as any).displayPreferenceModal();
        return false;
      }}
    >
      cookies
    </Link>
  );
}
