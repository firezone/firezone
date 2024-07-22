"use client";
import Link from "next/link";
import { Route } from "next";

type ButtonType = "cta" | "info" | "glass";

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
            className="group inline-flex items-center gap-2 text-sm px-5 py-2.5 text-white bg-primary-450 font-semibold hover:ring-2 tracking-tight rounded duration-50 transition transform"
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
    case "glass-cta":
      return (
        <Link href={href}>
          <button
            type="button"
            className="flex items-center gap-2 text-sm font-manrope font-semibold tracking-tight rounded-lg px-5 py-2.5 text-primary-50 border border-[rgba(255,242,231,0.5)] 
            shadow-[inset_0_-8px_32px_0_rgb(45,23,10),inset_0_8px_8px_0_rgba(57,39,4,0.34)] hover:ring-2 hover:ring-neutral-300
            duration-50 transition transform"
            style={{
              background: `
              radial-gradient(ellipse at center bottom, #FF4D00 0%, transparent 60%), 
              linear-gradient(to bottom, rgba(255, 255, 255, 0), rgba(255, 255, 255, 0.04))
            `,
            }}
          >
            {children}
          </button>
        </Link>
      );
  }
}
