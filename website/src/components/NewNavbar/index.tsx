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
import type { CustomFlowbiteTheme } from "flowbite-react";
import { usePathname } from "next/navigation";
import { HiBars3 } from "react-icons/hi2";
import Button from "@/components/Button";
import { HiArrowLongRight } from "react-icons/hi2";

const navbarTheme: CustomFlowbiteTheme["navbar"] = {
  root: {
    base: "fixed t-0 text-neutral-300 text-sm font-manrope z-50 w-full !p-5 md:p-8 bg-transparent transition-shadow",
    rounded: {
      on: "rounded",
      off: "",
    },
    bordered: {
      on: "border",
      off: "",
    },
    inner: {
      base: "mx-auto flex flex-wrap items-center justify-between",
      fluid: {
        on: "",
        off: "container",
      },
    },
  },
  brand: {
    base: "flex items-center",
  },
  collapse: {
    base: "w-full md:block md:w-auto shadow md:shadow-none",
    list: "mt-4 flex flex-col md:mt-0 md:flex-row md:space-x-8 md:text-md md:font-medium",
    hidden: {
      on: "hidden",
      off: "",
    },
  },
  link: {
    base: "block py-2 pl-3 pr-4 md:p-0 border-b border-neutral-200 md:border-transparent",
    active: {
      on: "bg-neutral-200 rounded text-white md:bg-transparent text-primary-450 font-semibold",
      off: "text-neutral-300 hover:text-primary-450 hover:bg-neutral-100 transition transform duration-50 md:hover:bg-transparent md:hover:border-b-2 md:hover:border-primary-450",
    },
    disabled: {
      on: "text-neutral-400 hover:cursor-not-allowed",
      off: "",
    },
  },
  toggle: {
    base: "inline-flex items-center rounded p-2 text-neutral-300 hover:bg-neutral-100 md:hidden",
    icon: "h-6 w-6 shrink-0",
  },
};

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
    <Navbar theme={navbarTheme}>
      <NavbarBrand as={Link} href="/">
        <Image
          width={150}
          height={150}
          src="/images/logo-text-white.svg"
          alt="Firezone Logo"
          className="flex w-32 "
        />
      </NavbarBrand>
      <div className="flex gap-2 md:order-2">
        <ActionLink
          href="https://app.firezone.dev/"
          className="py-2 pl-3 pr-4 text-sm md:p-0 font-medium text-neutral-300 md:border-transparent hover:text-primary-450 duration-50 transition transform"
          size="w-5 h-5 ml-1"
        >
          Sign in
        </ActionLink>
        <NavbarToggle barIcon={HiBars3} />
        <div className="hidden md:flex ">
          <Button type="cta" href="/contact/sales">
            Book a demo
            <HiArrowLongRight
              className={
                "group-hover:translate-x-1 group-hover:scale-110 duration-100 transform transition "
              }
            />
          </Button>
        </div>
      </div>
      <NavbarCollapse>
        <Dropdown label="Product" inline>
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
        <NavbarLink href="/pricing">Pricing</NavbarLink>
        <NavbarLink href="/blog">Blog</NavbarLink>
        <NavbarLink href="/support">Support</NavbarLink>

        <div className="md:hidden">
          <NavbarLink href="/contact/sales">Book a demo</NavbarLink>
        </div>
      </NavbarCollapse>
    </Navbar>
  );
}
