"use client";
import Image from "next/image";
import Link from "next/link";
import SidebarToggle from "./SidebarToggle";
import { Navbar } from "flowbite-react";
import { usePathname } from "next/navigation";
import DeployButton from "@/components/DeployButton";

export default function RootNavbar() {
  const p = usePathname() || "";

  return (
    <header>
      <nav className="fixed top-0 left-0 right-0 bg-white border-b border-neutral-200 z-50">
        <div className="w-full flex flex-wrap py-2 justify-between items-center">
          <div className="flex justify-start items-center">
            <SidebarToggle />
            <Link href="/">
              <Image
                width={150}
                height={150}
                src="/images/logo-text.svg"
                className="ml-2 mr-5"
                alt="Firezone Logo"
              />
            </Link>
            <span className="p-2"></span>
            <Link
              className={
                (p == "/" ? "text-neutral-900 underline" : "text-neutral-800") +
                " p-1 mr-1 hover:text-neutral-900 hover:underline rounded-lg"
              }
              href="/"
            >
              Home
            </Link>
            <span className="p-2"></span>
            <Link
              className={
                (p.startsWith("/docs")
                  ? "text-neutral-900 underline"
                  : "text-neutral-800") +
                " p-1 mr-1 hover:text-neutral-900 hover:underline rounded-lg"
              }
              href="/docs"
            >
              Docs
            </Link>
            <span className="p-2"></span>
            <Link
              className={
                (p.startsWith("/contact/sales")
                  ? "text-neutral-900 underline"
                  : "text-neutral-800") +
                " p-1 mr-1 hover:text-neutral-900 hover:underline rounded-lg"
              }
              href="/contact/sales"
            >
              Contact
            </Link>
            <span className="p-2"></span>
            <Link
              className={
                (p.startsWith("/contact/newsletter")
                  ? "text-neutral-900 underline"
                  : "text-neutral-800") +
                " p-2 mr-2 hover:text-neutral-900 hover:underline rounded-lg"
              }
              href="/contact/newsletter"
            >
              Newsletter
            </Link>
          </div>
          <div className="hidden md:flex items-center lg:order-2">
            <Link
              href="https://github.com/firezone/firezone"
              className="p-2 mr-1"
              aria-label="GitHub Repository"
            >
              <Image
                alt="Github Repo stars"
                height={50}
                width={100}
                className=""
                src="https://img.shields.io/github/stars/firezone/firezone?label=Stars&amp;style=social"
              />
            </Link>
            <span className="mr-2">
              <DeployButton />
            </span>
          </div>
        </div>
      </nav>
    </header>
  );
}
