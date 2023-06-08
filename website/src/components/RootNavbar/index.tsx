"use client";
import Image from "next/image";
import Link from "next/link";
import SidebarToggle from "./SidebarToggle";
import { Navbar } from "flowbite-react";
import { usePathname } from "next/navigation";

export default function RootNavbar() {
  const p = usePathname();

  return (
    <header>
      <nav className="fixed top-0 left-0 right-0 bg-white border-b border-gray-200 z-50">
        <div className="w-full flex flex-wrap py-2 justify-between items-center">
          <div className="flex justify-start items-center">
            <SidebarToggle />
            <Link href="/">
              <Image
                width={150}
                height={150}
                src="/logo.svg"
                className="ml-2 mr-5 h-auto"
                alt="Firezone Logo"
              />
            </Link>
            <Link
              className={
                (p.startsWith("/docs")
                  ? "text-gray-900 underline"
                  : "text-gray-600") +
                " p-2 mr-2 hover:text-gray-900 hover:underline rounded-lg"
              }
              href="/docs"
            >
              Docs
            </Link>
            <Link
              className={
                (p.startsWith("/contact")
                  ? "text-gray-900 underline"
                  : "text-gray-600") +
                " p-2 mr-2 hover:text-gray-900 hover:underline rounded-lg"
              }
              href="/contact/sales"
            >
              Contact
            </Link>
          </div>
          <div className="flex items-center lg:order-2"></div>
        </div>
      </nav>
    </header>
  );
}
