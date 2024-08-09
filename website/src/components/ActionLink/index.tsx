import Link from "next/link";
import { Route } from "next";
import { HiArrowLongRight } from "react-icons/hi2";

export default function ActionLink({
  size = "ml-2 -mr-1 w-6 h-6",
  children,
  href,
  className,
  color,
  transitionColor,
}: {
  size?: string;
  children: React.ReactNode;
  href: Route<string>;
  className?: string;
  color?: string;
  transitionColor?: string;
}) {
  return (
    <Link
      href={href}
      className={`${className} group inline-flex justify-center
                 items-center py-2 font-semibold border-b-[2px] ${
                   "text-" + color
                 } ${`border-` + color}
                 ${
                   transitionColor === "white" &&
                   "hover:text-neutral-100 hover:border-neutral-100"
                 } duration-50 transform transition
      `}
    >
      {children}
      <HiArrowLongRight
        className={
          `${
            transitionColor === "white" && "group-hover:text-neutral-100"
          } group-hover:translate-x-1 group-hover:scale-110 duration-100 transform transition ` +
          size
        }
      />
    </Link>
  );
}
