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
                 } ${"border-" + color} 
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

{
  /* <button
  type="button"
  className="group md:text-lg text-md md:w-48 w-full inline-flex justify-center items-center py-0 px-0 font-semibold text-center text-white rounded duration-50 transform transition"
>
  <Link
    href="https://app.firezone.dev/sign_up"
    className="text-neutral-300 w-full group inline-flex justify-center
                 items-center py-2 font-semibold border-b-[1px] border-neutral-200 hover:border-primary-450 hover:text-primary-450 transition transform duration-50"
  >
    <p>Try Firezone for free</p>
    <HiArrowLongRight className="group-hover:text-primary-450 group-hover:translate-x-1 group-hover:scale-110 duration-50 transition transform ml-2 -mr-1 w-6 h-6" />
  </Link>
</button>; */
}
