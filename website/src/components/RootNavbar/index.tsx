"use client";
import Image from "next/image";
import Link from "next/link";
import DocsSidebarToggle from "./DocsSidebarToggle";
import KbSidebarToggle from "./KbSidebarToggle";
import { Navbar } from "flowbite-react";
import { usePathname } from "next/navigation";
import RequestDemoButton from "@/components/RequestDemoButton";
import { useEffect } from "react";
import { initFlowbite, Dropdown } from "flowbite";
import { HiChevronDown } from "react-icons/hi2";

export default function RootNavbar() {
  const p = usePathname() || "";
  let productDropdown: any = null;
  let docsDropdown: any = null;

  useEffect(() => {
    if (!productDropdown) {
      productDropdown = new Dropdown(
        document.getElementById("product-dropdown-menu"),
        document.getElementById("product-dropdown-link")
      );
    }
    if (!docsDropdown) {
      docsDropdown = new Dropdown(
        document.getElementById("docs-dropdown-menu"),
        document.getElementById("docs-dropdown-link")
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

    if (!docsDropdown) {
      docsDropdown = new Dropdown(
        document.getElementById("docs-dropdown-menu"),
        document.getElementById("docs-dropdown-link")
      );
    }

    productDropdown.hide();
    docsDropdown.hide();
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
                className="md:hidden w-9 ml-2 flex"
                alt="Firezone Logo"
              />
            </Link>
            <Link href="/">
              <Image
                width={150}
                height={150}
                src="/images/logo-text.svg"
                className="hidden md:flex w-32 sm:w-40 ml-2 mr-2 sm:mr-5"
                alt="Firezone Logo"
              />
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
                    href="/contact/sales"
                    className="text-neutral-800 block px-4 py-2 font-medium hover:underline hover:bg-neutral-100 hover:text-neutral-900"
                  >
                    Request Demo
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
                    href="/product/early-access"
                    className={
                      (p == "/product/early-access"
                        ? "text-neutral-900 underline"
                        : "text-neutral-800") +
                      " block px-4 py-2 font-medium hover:underline hover:bg-neutral-100 hover:text-neutral-900"
                    }
                  >
                    Early Access
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
                <li>
                  {/* TODO: use <Link> here, toggling dropdown */}
                  <Link
                    onClick={hideDropdown}
                    href="https://github.com/firezone/firezone"
                    className="text-neutral-800 block px-4 py-2 font-medium hover:underline hover:bg-neutral-100 hover:text-neutral-900"
                  >
                    Open Source
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
            <button
              id="docs-dropdown-link"
              className={
                (p.startsWith("/docs") || p.startsWith("/kb")
                  ? "text-neutral-900"
                  : "text-neutral-800") +
                " hover:text-neutral-900 flex items-center justify-between p-0 sm:p-1 mr-1"
              }
            >
              <span
                className={
                  "hover:underline font-medium " +
                  (p.startsWith("/docs") || p.startsWith("/kb")
                    ? "underline"
                    : "")
                }
              >
                Docs
              </span>
              <HiChevronDown className="w-3 h-3 mx-1" />
            </button>
            <div
              id="docs-dropdown-menu"
              className="z-10 hidden bg-white divide-y divide-gray-100 rounded shadow-lg w-44"
            >
              <ul className="py-2" aria-labelledby="product-dropdown-link">
                <li>
                  <Link
                    onClick={hideDropdown}
                    href="/kb"
                    className={
                      (p.startsWith("/kb")
                        ? "text-neutral-900 underline"
                        : "text-neutral-800") +
                      " block px-4 py-2 font-medium hover:underline hover:bg-neutral-100 hover:text-neutral-900"
                    }
                  >
                    Latest Docs
                  </Link>
                </li>
                <li>
                  <Link
                    onClick={hideDropdown}
                    href="/docs"
                    className={
                      (p.startsWith("/docs")
                        ? "text-neutral-900 underline"
                        : "text-neutral-800") +
                      " block px-4 py-2 font-medium hover:underline hover:bg-neutral-100 hover:text-neutral-900"
                    }
                  >
                    Legacy (0.7) Docs
                  </Link>
                </li>
              </ul>
            </div>
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
              <RequestDemoButton />
            </span>
          </div>
        </div>
      </nav>
    </header>
  );
}
