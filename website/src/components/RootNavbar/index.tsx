"use client";
import Image from "next/image";
import Link from "next/link";
import DocsSidebarToggle from "@/components/DocsSidebarToggle";
import { Navbar } from "flowbite-react";
import { usePathname } from "next/navigation";

export default function RootNavbar() {
  return (
    <header>
      <nav className="fixed top-0 left-0 right-0 bg-white border-b border-gray-200 z-50">
        <div className="max-w-screen-xl flex flex-wrap mx-auto py-2 justify-between items-center">
          <div className="flex justify-start items-center">
            <DocsSidebarToggle />
            <Link href="/">
              <Image
                width={150}
                height={150}
                src="/logo.svg"
                className="mr-3 h-auto"
                alt="Firezone Logo"
              />
            </Link>
          </div>
          <div className="flex items-center lg:order-2">
            <Link
              className="p-2 mr-1 text-gray-600 hover:text-gray-900 hover:bg-gray-100 rounded-lg"
              href="/docs"
            >
              Docs
            </Link>
            <Link
              className="p-2 mr-1 text-gray-600 hover:text-gray-900 hover:bg-gray-100 rounded-lg"
              href="/contact/sales"
            >
              Contact
            </Link>
          </div>
        </div>
      </nav>
    </header>
  );
}
