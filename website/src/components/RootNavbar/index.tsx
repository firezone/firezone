"use client";
import Image from "next/image";
import { Navbar } from "flowbite-react";

export default function RootNavbar() {
  return (
    <Navbar className="bg-white border-b border-gray-200 px-4 py-2.5 dark:bg-gray-800 dark:border-gray-700 fixed left-0 right-0 top-0 z-50">
      <Navbar.Brand href="/">
        <Image
          width={150}
          height={150}
          src="/logo.svg"
          className="mr-3 h-6 sm:h-9"
          alt="Firezone Logo"
        />
      </Navbar.Brand>
      <Navbar.Collapse>
        <Navbar.Link href="/docs">Docs</Navbar.Link>
        <Navbar.Link href="/contact/sales">Contact</Navbar.Link>
      </Navbar.Collapse>
    </Navbar>
  );
}
