import Link from "next/link";
import { Route } from "next";
import { usePathname } from "next/navigation";
import { HiMinus } from "react-icons/hi2";

export default function Item({
  topLevel,
  nested,
  href,
  label,
}: {
  topLevel?: boolean;
  nested?: boolean;
  href: Route<string>;
  label: string;
}) {
  function active(path: string) {
    return usePathname() == path;
  }

  return (
    <Link
      href={href}
      className={
        (active(href) ? "bg-neutral-100 " : "") +
        "pb-0.5 flex " +
        ((!topLevel && "border-l") || "") +
        " border-0.5 border-neutral-500 items-center text-left text-base font-normal text-neutral-900 hover:bg-neutral-100"
      }
    >
      {!topLevel && <HiMinus className="w-2 h-2" />}
      <span
        className={
          (nested ? "ml-4 " : "") +
          (active(href) ? "font-medium " : "") +
          "ml-2" +
          ((topLevel && " pl-0.5") || "")
        }
      >
        {label}
      </span>
    </Link>
  );
}
