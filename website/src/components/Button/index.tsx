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
  href: URL | Route<string>;
  children: React.ReactNode;
}) {
  switch (type) {
    case "cta":
      return (
        <Link href={href}>
          <button
            type="button"
            className="text-md md:text-base px-5 py-2.5 text-white bg-primary-450 font-semibold hover:ring-1 hover:ring-primary-400 tracking-tight rounded-sm duration-50 transition transform"
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
            className="text-md md:text-base px-5 py-2.5 text-primary-450 bg-white border border-primary-450 hover:ring-1 hover:ring-primary-400 font-semibold tracking-tight rounded-sm duration-50 transition transform"
          >
            {children}
          </button>
        </Link>
      );
  }
}
