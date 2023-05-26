"use client";
import Image from "next/image";
import { Navbar } from "flowbite-react";

export default function RootNavbar() {
  return (
    <Navbar fluid={true} rounded={true}>
      <Navbar.Brand href="/">
        <Image
          width={300}
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
