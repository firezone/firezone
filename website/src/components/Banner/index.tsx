import Link from "next/link";
import { Route } from "next";
import Image from "next/image";
import { UrlObject } from "url";

export default function Banner({
  active,
  href = "/",
  children,
}: {
  active: boolean;
  href?: Route<string> | UrlObject;
  children: React.ReactNode;
}) {
  if (!active) return null;
  return <Link href={href}>{children}</Link>;
}
