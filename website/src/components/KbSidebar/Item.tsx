import Link from "next/link";
import { Route } from "next";
import { usePathname } from "next/navigation";

export default function Item({
  href,
  label,
}: {
  href: Route<string>;
  label: string;
}) {
  const p = usePathname();

  function active(path: string) {
    return p == path ? "bg-neutral-100  " : "";
  }

  return (
    <Link
      href={href}
      className={[
        active(href),
        "flex items-center text-left rounded text-base font-normal text-neutral-900 hover:bg-neutral-100  ",
      ].join(" ")}
    >
      <span className="ml-3">{label}</span>
    </Link>
  );
}
