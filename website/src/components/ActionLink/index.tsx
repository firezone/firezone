import Link from "next/link";
import { ArrowLongRightIcon } from "@heroicons/react/24/solid";

export default function ActionLink({
  children,
  href,
  className,
}: {
  children: React.ReactNode;
  href: string;
  className?: string;
}) {
  return (
    <Link href={href} className={`${className} group`}>
      {children}
      <ArrowLongRightIcon className="group-hover:translate-x-1 group-hover:scale-110 duration-100 transform transition ml-2 -mr-1 w-6 h-6" />
    </Link>
  );
}
