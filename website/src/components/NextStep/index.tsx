import Link from "next/link";
import { HiArrowLongRight } from "react-icons/hi2";
import { Route } from "next";

export default function NextStep({
  children,
  href,
}: {
  children: React.ReactNode;
  href: URL | Route<string>;
}) {
  return (
    <div className="flex justify-end">
      <Link href={href}>
        <button
          type="button"
          className="text-white font-bold tracking-tight rounded-sm duration-0 hover:scale-105 transition transform shadow-lg text-sm px-5 py-2.5 bg-accent-450 hover:bg-accent-700"
        >
          {children}
          <HiArrowLongRight className="inline-flex ml-2 w-6 h-6" />
        </button>
      </Link>
    </div>
  );
}
