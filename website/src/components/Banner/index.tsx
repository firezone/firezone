import Link from "next/link";
import { Route } from "next";

export default function Banner({
  active,
  href = "/",
  children,
}: {
  active: boolean;
  href?: URL | Route<string>;
  children: React.ReactNode;
}) {
  if (!active) return null;

  return (
    <Link
      href={href}
      className={`group mb-6 bg-accent-900 text-accent-200 hover:text-accent-100 hover:ring-[0.5px] ring-accent-700 text-sm rounded-2xl px-1 py-1`}
    >
      {children}
    </Link>
  );
}
