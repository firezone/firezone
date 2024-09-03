import Link from "next/link";
import Image from "next/image";

export default function Banner({
  active,
  href,
  children,
}: {
  active: boolean;
  href: string;
  children: React.ReactNode;
}) {
  if (!active) return null;
  return <Link href={href}>{children}</Link>;
}
