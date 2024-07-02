"use client";
import Link from "next/link";
import { Route } from "next";

type ButtonType = "cta" | "info";

export default function Button({
  type = "cta",
  href,
  children,
}: {
  type?: ButtonType;
  href: Route<string>;
  children: React.ReactNode;
}) {
  switch (type) {
    case "cta":
      return (
        <Link href={href}>
          <button
            type="button"
            className="text-md md:text-base px-5 py-2.5 text-white bg-primary-450 font-semibold hover:ring-2 hover:ring-primary-200 tracking-tight rounded duration-50 transition transform"
          >
            {children}
          </button>
        </Link>
      );
    case "info":
      return (
        <Link href={href}>
          <button
            type="button"
            className="text-md md:text-base px-5 py-2.5 text-primary-450 bg-white border border-primary-450 hover:ring-2 hover:ring-primary-300 font-semibold tracking-tight rounded duration-50 transition transform"
          >
            {children}
          </button>
        </Link>
      );
  }
}
