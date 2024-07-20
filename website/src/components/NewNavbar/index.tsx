"use client";
import Link from "next/link";
import Image from "next/image";
import {
  Navbar,
  NavbarBrand,
  NavbarCollapse,
  NavbarLink as FlowbiteNavbarLink,
  NavbarToggle,
  Dropdown,
  DropdownItem as FlowbiteDropdownItem,
} from "flowbite-react";
import ActionLink from "@/components/ActionLink";
import { usePathname } from "next/navigation";
import { HiBars3 } from "react-icons/hi2";

function NavbarLink({
  href,
  children,
}: {
  href: string;
  children: React.ReactNode;
}) {
  const p = usePathname();

  return (
    <FlowbiteNavbarLink
      href={href}
      as={Link}
      active={p.startsWith(href)}
      className="text-neutral-300 font-normal"
    >
      {children}
    </FlowbiteNavbarLink>
  );
}

function DropdownItem({
  href,
  children,
}: {
  href: string;
  children: React.ReactNode;
}) {
  return (
    <FlowbiteDropdownItem href={href} as={Link}>
      {children}
    </FlowbiteDropdownItem>
  );
}

export default function NewNavbar() {
  return (
    <Navbar className="font-manrope flex justify-between fixed t-0 z-50 w-full !px-12 !py-5 bg-transparent ">
      <NavbarBrand as={Link} href="/">
        <Image
          width={150}
          height={150}
          src="/images/logo-text-white.svg"
          alt="Firezone Logo"
          className="flex w-32 "
        />
      </NavbarBrand>
      <NavbarToggle barIcon={HiBars3} />
      <NavbarCollapse>
        <Dropdown label="Product" className="!text-white !font-normal" inline>
          <DropdownItem href="/kb/user-guides">Download</DropdownItem>
          <DropdownItem href="/contact/sales">Book a demo</DropdownItem>
          <DropdownItem href="/kb/use-cases">Use cases</DropdownItem>
          <DropdownItem href="https://www.github.com/firezone/firezone">
            Open source
          </DropdownItem>
          <DropdownItem href="https://github.com/orgs/firezone/projects/9">
            Roadmap
          </DropdownItem>
          <DropdownItem href="/product/newsletter">Newsletter</DropdownItem>
          <DropdownItem href="/changelog">Changelog</DropdownItem>
        </Dropdown>
        <NavbarLink href="/kb">Docs</NavbarLink>
        <NavbarLink href="/pricing">Manrope</NavbarLink>
        <NavbarLink href="/blog">Blog</NavbarLink>
        <NavbarLink href="/support">Support</NavbarLink>
        <div className="md:hidden">
          <NavbarLink href="/contact/sales">Book a demo</NavbarLink>
        </div>
        <ActionLink
          href="https://app.firezone.dev/"
          className="hidden md:inline-flex py-2 pl-3 pr-4 md:p-0 font-medium text-neutral-700 md:border-transparent hover:text-primary-450 hover:bg-neutral-200 md:hover:bg-transparent md:border-b-2 md:hover:border-primary-450 duration-50 transition transform"
          size="w-5 h-5 ml-1"
        >
          Sign in
        </ActionLink>
      </NavbarCollapse>
    </Navbar>
  );
}
