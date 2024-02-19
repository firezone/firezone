import Link from "next/link";
import { HiArrowLongRight } from "react-icons/hi2";
import { Route } from "next";

export default function NextStep({
  children,
  href,
}: {
  children: React.ReactNode;
  href: Route<string>;
}) {
  return (
    <div className="flex justify-end">
      <Link href={href}>
        <div>
          <HiArrowLongRight className="mx-auto w-12 h-12" />
          {children}
        </div>
      </Link>
    </div>
  );
}
