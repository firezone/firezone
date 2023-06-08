import Link from "next/link";
import { usePathname } from "next/navigation";

export default function Item({ href, label }: { href: string; label: string }) {
  const p = usePathname();

  function active(path: string) {
    return p == path ? "bg-gray-100 dark:bg-gray-700 " : "";
  }

  return (
    <Link
      href={href}
      className={[
        active(href),
        "flex items-center text-left rounded-lg text-base font-normal text-gray-900 hover:bg-gray-100 dark:text-white dark:hover:bg-gray-700",
      ].join(" ")}
    >
      <span className="ml-3">{label}</span>
    </Link>
  );
}
