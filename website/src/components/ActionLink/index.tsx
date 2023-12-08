import Link from "next/link";
import { Route } from "next";
import { HiArrowLongRight } from "react-icons/hi2";

export default function ActionLink({
  children,
  href,
  className,
}: {
  children: React.ReactNode;
  href: Route<string>;
  className?: string;
}) {
  return (
    <Link href={href} className={`${className} group`}>
      {children}
      <HiArrowLongRight className="group-hover:translate-x-1 group-hover:scale-110 duration-100 transform transition ml-2 -mr-1 w-6 h-6" />
    </Link>
  );
}
