import Link from "next/link";
import { Route } from "next";
import { usePathname } from "next/navigation";
import { HiMinus } from "react-icons/hi2";

export default function Item({
  children,
  topLevel,
  nested,
  href,
}: {
  children: React.ReactNode;
  topLevel?: boolean;
  nested?: boolean;
  href: Route<string>;
}) {
  function active(path: string) {
    return usePathname() == path;
  }

  return (
    <Link
      href={href}
      className={
        (active(href) ? "bg-neutral-200 " : "") +
        "pb-0.5 flex w-full " +
        ((!topLevel && "border-l") || "") +
        " border-0.5 border-neutral-500 items-center text-left text-base font-medium text-neutral-700 hover:bg-neutral-100"
      }
    >
      {!topLevel && <HiMinus className="w-2 h-2" />}
      {nested && <HiMinus className="w-2 h-2 -ml-1" />}
      <span
        className={
          (nested ? "ml-5 " : "") +
          (active(href) ? "text-neutral-800 " : "") +
          "ml-2 w-full" +
          ((topLevel && " pl-0.5") || "")
        }
      >
        {children}
      </span>
    </Link>
  );
}
