"use client";
import Image from "next/image";
import Link from "next/link";
import ActionLink from "@/components/ActionLink";
import {
  Navbar,
  NavbarBrand,
  NavbarCollapse,
  NavbarLink as FlowbiteNavbarLink,
  NavbarToggle,
  Dropdown,
  DropdownItem as FlowbiteDropdownItem,
} from "flowbite-react";
import { usePathname } from "next/navigation";
import Button from "@/components/Button";
import { HiChevronDown } from "react-icons/hi2";
import type { CustomFlowbiteTheme } from "flowbite-react";
import { HiBars3 } from "react-icons/hi2";
import { useDrawer } from "@/components/Providers/DrawerProvider";

const navbarTheme: CustomFlowbiteTheme["navbar"] = {
  root: {
    base: "fixed top-0 left-0 right-0 z-50 items-center bg-white px-2 py-2.5 sm:px-4",
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
      off: "text-neutral-700 hover:text-primary-450 hover:bg-neutral-100 transition transform duration-50 md:hover:bg-transparent md:hover:border-b-2 md:hover:border-primary-450",
    },
    disabled: {
      on: "text-neutral-400 hover:cursor-not-allowed",
      off: "",
    },
  },
  toggle: {
    base: "inline-flex items-center rounded p-2 text-neutral-700 hover:bg-neutral-100 md:hidden",
    icon: "h-6 w-6 shrink-0",
  },
};

const dropdownTheme: CustomFlowbiteTheme["dropdown"] = {
  arrowIcon: "ml-2 h-4 w-4",
  content: "py-1 focus:outline-none",
  floating: {
    animation: "transition-opacity",
    arrow: {
      base: "absolute z-10 h-2 w-2 rotate-45",
      style: {
        dark: "bg-neutral-900 dark:bg-neutral-700",
        light: "bg-white",
        auto: "bg-white",
      },
      placement: "-4px",
    },
    base: "z-10 w-fit divide-y divide-neutral-100 rounded shadow focus:outline-none",
    content: "py-1 text-base text-neutral-700",
    divider: "my-1 h-px bg-neutral-100",
    header: "block px-4 py-2 text-sm text-neutral-700",
    hidden: "invisible opacity-0",
    item: {
      container: "",
      base: "flex w-32 cursor-pointer items-center justify-start px-4 py-2 text-md font-medium text-neutral-700 hover:bg-neutral-100 focus:bg-neutral-100 focus:outline-none",
      icon: "mr-2 h-4 w-4",
    },
    style: {
      dark: "bg-neutral-900 text-white dark:bg-neutral-700",
      light: "border border-neutral-200 bg-white text-neutral-900",
      auto: "border border-neutral-200 bg-white text-neutral-900",
    },
    target: "w-fit",
  },
  inlineWrapper:
    "flex items-center py-2 pl-3 pr-4 md:p-0 text-neutral-700 hover:text-primary-450 md:border-transparent md:border-b-2 md:hover:border-primary-450 duration-50 transition transform",
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
    <FlowbiteNavbarLink href={href} as={Link} active={p.startsWith(href)}>
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

function SidebarToggle() {
  const { toggle } = useDrawer();
  const p = usePathname();

  if (p.startsWith("/kb") || p.startsWith("/docs")) {
    return (
      <button
        type="button"
        onClick={toggle}
        className="p-2 text-neutral-700 md:hidden hover:bg-neutral-100"
      >
        <HiBars3 aria-hidden="true" className="w-6 h-6 shrink-0" />
        <span className="sr-only">Toggle sidebar</span>
      </button>
    );
  } else {
    return null;
  }
}

export default function RootNavbar() {
  return (
    <Navbar theme={navbarTheme} fluid>
      <SidebarToggle />
      <NavbarBrand as={Link} href="/">
        <Image
          width={150}
          height={150}
          src="/images/logo-main.svg"
          className="lg:hidden w-9 ml-2 flex"
          alt="Firezone Logo"
        />
        <Image
          width={150}
          height={150}
          src="/images/logo-text.svg"
          alt="Firezone Logo"
          className="hidden lg:flex w-32 sm:w-40 ml-2 mr-2 sm:mr-5"
        />
      </NavbarBrand>
      <NavbarToggle barIcon={HiBars3} />
      <NavbarCollapse>
        <Dropdown theme={dropdownTheme} label="Product" inline>
          <DropdownItem href="/changelog">Changelog</DropdownItem>
          <DropdownItem href="/kb/user-guides">Download</DropdownItem>
          <DropdownItem href="/contact/sales">Book a demo</DropdownItem>
          <DropdownItem href="https://www.github.com/firezone/firezone">
            Open source
          </DropdownItem>
          <DropdownItem href="https://github.com/orgs/firezone/projects/9">
            Roadmap
          </DropdownItem>
          <DropdownItem href="/product/newsletter">Newsletter</DropdownItem>
        </Dropdown>
        <NavbarLink href="/kb">Docs</NavbarLink>
        <NavbarLink href="/pricing">Pricing</NavbarLink>
        <NavbarLink href="/blog">Blog</NavbarLink>
        <NavbarLink href="/support">Support</NavbarLink>
        <div className="md:hidden">
          <NavbarLink href="/contact/sales">Book a demo</NavbarLink>
        </div>
        <ActionLink
          href="https://app.firezone.dev/"
          className="hidden md:inline-flex py-2 pl-3 pr-4 md:p-0 font-medium text-neutral-700 md:border-transparent hover:text-primary-450 hover:bg-neutral-200 md:hover:bg-transparent md:border-b-2 md:hover:border-primary-450 duration-50 transition transform"
          size="w-5 h-5"
        >
          Sign in
        </ActionLink>
      </NavbarCollapse>
      <div className="hidden md:flex space-x-4 items-center">
        <Link
          className="block py-2 pl-3 pr-4 md:p-0 font-medium text-neutral-700 md:border-transparent hover:text-primary-450 md:border-b-2 hover:border-primary-450 duration-50 transition transform"
          href="https://app.firezone.dev/sign_up"
        >
          Sign up
        </Link>
        <Button type="cta" href="/contact/sales">
          Book a demo
        </Button>
      </div>
    </Navbar>
  );
}
