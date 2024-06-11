"use client";
import Image from "next/image";
import Link from "next/link";
import ActionLink from "@/components/ActionLink";
import DocsSidebarToggle from "./DocsSidebarToggle";
import KbSidebarToggle from "./KbSidebarToggle";
import { Navbar } from "flowbite-react";
import { usePathname } from "next/navigation";
import { RequestDemoButton, SignUpButton } from "@/components/Buttons";
import { useEffect } from "react";
import { initFlowbite, Dropdown } from "flowbite";
import { HiChevronDown } from "react-icons/hi2";

export default function RootNavbar() {
  const p = usePathname() || "";
  let productDropdown: any = null;

  useEffect(() => {
    if (!productDropdown) {
      productDropdown = new Dropdown(
        document.getElementById("product-dropdown-menu"),
        document.getElementById("product-dropdown-link")
      );
    }
    // Manually init flowbite's data-toggle listeners since we're using custom components
    initFlowbite();
  }, []);

  const hideDropdown = () => {
    if (!productDropdown) {
      productDropdown = new Dropdown(
        document.getElementById("product-dropdown-menu"),
        document.getElementById("product-dropdown-link")
      );
    }

    productDropdown.hide();
  };

  return (
    <header>
      <nav className="h-14 fixed top-0 left-0 right-0 bg-white border-b items-center flex border-neutral-200 z-50">
        <div className="w-full flex flex-wrap py-2 justify-between items-center">
          <div className="flex justify-start items-center">
            {p.startsWith("/docs") ? <DocsSidebarToggle /> : null}
            {p.startsWith("/kb") ? <KbSidebarToggle /> : null}
            <Link href="/">
              <Image
                width={150}
                height={150}
                src="/images/logo-main.svg"
                className="lg:hidden w-9 ml-2 flex"
                alt="Firezone Logo"
              />
            </Link>
            <Link href="/">
              <span className="hidden lg:flex w-32 sm:w-40 ml-2 mr-2 sm:mr-5">
                <Image
                  width={150}
                  height={150}
                  src="/images/logo-text.svg"
                  alt="Firezone Logo"
                />
              </span>
            </Link>
            <span className="p-2"></span>
            <button
              id="product-dropdown-link"
              className={
                (p.startsWith("/product")
                  ? "text-neutral-900"
                  : "text-neutral-800") +
                " hover:text-neutral-900 flex items-center justify-between p-0 sm:p-1 mr-1"
              }
            >
              <span
                className={
                  "hover:underline font-medium " +
                  (p.startsWith("/product") ? "underline" : "")
                }
              >
                Product
              </span>
              <HiChevronDown className="w-3 h-3 mx-1" />
            </button>
            <div
              id="product-dropdown-menu"
              className="z-10 hidden bg-white divide-y divide-gray-100 rounded shadow-lg w-44"
            >
              <ul className="py-2" aria-labelledby="product-dropdown-link">
                <li>
                  <Link
                    onClick={hideDropdown}
                    href="/kb/user-guides"
                    className={
                      (p == "/kb/user-guides"
                        ? "text-neutral-900 underline"
                        : "text-neutral-800") +
                      " block px-4 py-2 font-medium hover:underline hover:bg-neutral-100 hover:text-neutral-900"
                    }
                  >
                    Download
                  </Link>
                </li>
                <li>
                  <Link
                    onClick={hideDropdown}
                    href="/contact/sales"
                    className="text-neutral-800 block px-4 py-2 font-medium hover:underline hover:bg-neutral-100 hover:text-neutral-900"
                  >
                    Request Demo
                  </Link>
                </li>
                <li>
                  <Link
                    onClick={hideDropdown}
                    href="https://github.com/firezone/firezone"
                    className="text-neutral-800 block px-4 py-2 font-medium hover:underline hover:bg-neutral-100 hover:text-neutral-900"
                  >
                    Open Source
                  </Link>
                </li>
                <li>
                  <Link
                    onClick={hideDropdown}
                    href="https://github.com/orgs/firezone/projects/9"
                    className="text-neutral-800 block px-4 py-2 font-medium hover:underline hover:bg-neutral-100 hover:text-neutral-900"
                  >
                    Roadmap
                  </Link>
                </li>
                <li>
                  <Link
                    onClick={hideDropdown}
                    href="/product/newsletter"
                    className={
                      (p.startsWith("/product/newsletter")
                        ? "text-neutral-900 underline"
                        : "text-neutral-800") +
                      " block px-4 py-2 font-medium hover:underline hover:bg-neutral-100 hover:text-neutral-900"
                    }
                  >
                    Newsletter
                  </Link>
                </li>
              </ul>
            </div>
            <Link
              className={
                (p.startsWith("/blog")
                  ? "text-neutral-900 underline"
                  : "text-neutral-800") +
                " p-2 mr-4 font-medium hover:text-neutral-900 hover:underline"
              }
              href="/blog"
            >
              Blog
            </Link>
            <Link
              className={
                (p.startsWith("/kb")
                  ? "text-neutral-900 underline"
                  : "text-neutral-800") +
                " p-2 mr-4 font-medium hover:text-neutral-900 hover:underline"
              }
              href="/kb"
            >
              Docs
            </Link>
            <Link
              className={
                (p == "/pricing"
                  ? "text-neutral-900 underline"
                  : "text-neutral-800") +
                " p-0 sm:p-1 mr-1 font-medium hover:text-neutral-900 hover:underline"
              }
              href="/pricing"
            >
              Pricing
            </Link>
          </div>
          <div className="hidden sm:flex space-x-2.5 items-center sm:order-2 mr-2">
            <Link
              href="https://github.com/firezone/firezone"
              aria-label="GitHub Repository"
            >
              {/* NextJS's image component has issues with shields images */}
              <span className="md:w-24 w-16 flex">
                <img
                  className="grow"
                  alt="Github Repo stars"
                  src="https://img.shields.io/github/stars/firezone/firezone"
                />
              </span>
            </Link>
            <SignUpButton />
            <RequestDemoButton />
            <ActionLink
              href="https://app.firezone.dev/"
              className="hover:underline hidden sm:inline-flex sm:text-sm md:text-base"
              size="ml-1 mr-1 w-5 h-5"
            >
              Sign in
            </ActionLink>
          </div>
        </div>
      </nav>
    </header>
  );
}
