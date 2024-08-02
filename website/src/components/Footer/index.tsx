"use client";

import Link from "next/link";
import ActionLink from "@/components/ActionLink";
import Image from "next/image";
import ConsentPreferences from "@/components/ConsentPreferences";
import { HiArrowLongRight } from "react-icons/hi2";
import {
  LinkedInIcon,
  GitHubIcon,
  XIcon,
  AppleIcon,
  WindowsIcon,
  LinuxIcon,
  AndroidIcon,
} from "@/components/Icons";

export default function Footer() {
  return (
    <footer className="relative bg-neutral-900 py-16 md:px-16 px-4 text-neutral-500">
      <div className="flex flex-col justify-center items-center text-center">
        <h3 className="text-neutral-200 mb-4 text-4xl md:text-6xl text-pretty tracking-tight justify-center font-semibold">
          Ready to get started?
        </h3>
        <h4 className="text-neutral-200 text-md tracking-tight">
          Give your organization the protection it deserves.
        </h4>
        <div className="flex sm:flex-row flex-col justify-center sm:items-end items-center sm:w-fit w-full sm:gap-8 gap-4 my-8">
          <div className=" mx-auto px-4 md:px-0 ">
            <button
              type="button"
              className="text-sm inline-flex md:w-48 w-full shadow-lg justify-center items-center py-2 px-5 font-semibold text-center text-white rounded bg-primary-450 hover:ring-2 hover:ring-primary-500 duration-50 transform transition"
            >
              <Link href="/contact/sales">Book a demo</Link>
              <HiArrowLongRight className="ml-2 -mr-1 w-6 h-6" />
            </button>
            <p className="mt-3 text-xs text-neutral-400">
              Get a personalized walkthrough of Firezone.
            </p>
          </div>
          <div className=" mx-auto ">
            <button
              type="button"
              className="group text-sm md:w-48 w-full inline-flex justify-center items-center py-0 px-0 font-semibold text-center text-white rounded hover:ring-2 hover:ring-primary-400 duration-50 transform transition"
            >
              <Link
                href="https://app.firezone.dev/sign_up"
                className="text-neutral-300 w-full group inline-flex justify-center
                 items-center py-2 text-sm font-semibold border-b-[1px] border-neutral-200 hover:border-primary-450 hover:text-primary-450 transition transform duration-50"
              >
                <p>Try Firezone for free</p>
                <HiArrowLongRight className="group-hover:translate-x-1 group-hover:scale-110 duration-50 transition transform ml-2 -mr-1 w-5 h-5" />
              </Link>
            </button>
            <p className="mt-3 text-xs text-neutral-400">
              No credit card required. Cancel anytime.
            </p>
          </div>
        </div>
      </div>
      <div className="mx-auto w-full max-w-screen-xl p-4 py-6 lg:py-8">
        <div className="flex md:flex-row flex-col md:justify-between gap-12">
          <div className="flex md:flex-col justify-between">
            <div className="">
              <Link href="/">
                <Image
                  width={150}
                  height={150}
                  src="/images/logo-text-dark.svg"
                  alt="Firezone Logo"
                  className="mb-4"
                />
              </Link>
              <Link href="https://www.ycombinator.com/companies/firezone">
                <Image
                  width={125}
                  height={125}
                  src="/images/yc-logo.svg"
                  alt="YC Logo"
                />
              </Link>
            </div>
            <Link href="https://trust.firezone.dev">
              <Image
                alt="SOC2 badge"
                width={75}
                height={75}
                src="/images/soc2.svg"
              />
            </Link>
          </div>
          <div className="text-sm md:w-1/3 grid grid-cols-2 content-end md:text-right">
            <div>
              <h2 className="mb-6 font-semibold uppercase md:justify-end">
                Company
              </h2>
              <ul className="font-medium">
                <li className="mb-4">
                  <Link
                    href="/"
                    className="text-neutral-200 hover:underline hover:text-neutral-50"
                  >
                    Home
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="/about"
                    className="text-neutral-200 hover:underline hover:text-neutral-50"
                  >
                    About
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="/pricing"
                    className="text-neutral-200 hover:underline hover:text-neutral-50"
                  >
                    Pricing
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="https://github.com/orgs/firezone/projects/9"
                    className="text-neutral-200 hover:underline hover:text-neutral-50"
                  >
                    Roadmap
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="/blog"
                    className="text-neutral-200 hover:underline hover:text-neutral-50"
                  >
                    Blog
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="/product/newsletter"
                    className="text-neutral-200 hover:underline hover:text-neutral-50"
                  >
                    Newsletter
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="https://www.ycombinator.com/companies/firezone"
                    className="text-neutral-200 hover:underline hover:text-neutral-50"
                  >
                    Jobs
                  </Link>
                </li>
              </ul>
            </div>
            <div>
              <h2 className="mb-6 text-sm font-semibold uppercase md:justify-end">
                Resources
              </h2>
              <ul className=" font-medium">
                <li className="mb-4">
                  <Link
                    href="/kb"
                    className="text-neutral-200 hover:underline hover:text-neutral-50"
                  >
                    Docs
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="/support"
                    className="text-neutral-200 hover:underline hover:text-neutral-50"
                  >
                    Support
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="/changelog"
                    className="text-neutral-200 hover:underline hover:text-neutral-50"
                  >
                    Changelog
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="https://trust.firezone.dev/"
                    className="text-neutral-200 hover:underline hover:text-neutral-50"
                  >
                    Trust Center
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="/contact/sales"
                    className="text-neutral-200 hover:underline hover:text-neutral-50"
                  >
                    Sales
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="https://discourse.firez.one"
                    className="text-neutral-200 hover:underline hover:text-neutral-50"
                  >
                    Forums
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="https://discord.gg/DY8gxpSgep"
                    className="text-neutral-200 hover:underline hover:text-neutral-50"
                  >
                    Discord
                  </Link>
                </li>
              </ul>
            </div>
          </div>
        </div>
        <div className="sm:flex sm:justify-between sm:items-center mt-4 sm:mt-8">
          <div className="text-xs">
            <p>WireGuard is a registered trademark of Jason A. Donenfeld.</p>
            <p>Firezone is a registered trademark of Firezone, Inc.</p>
          </div>
          <div className="mt-4 sm:mt-0">
            <ActionLink
              href="https://probe.sh"
              size="ml-1 -mr-1 w-5 h-5"
              className="text-neutral-200 text-sm hover:underline hover:text-neutral-50"
            >
              Test your WireGuard connection
            </ActionLink>
          </div>
        </div>
        <hr className="my-2 border-neutral-500 sm:mx-auto md:my-4" />
        <div className="flex grid sm:grid-cols-3">
          <div className="text-xs">
            © 2024{" "}
            <Link
              href="/"
              className="text-neutral-200 hover:underline hover:text-neutral-50"
            >
              Firezone, Inc.
            </Link>{" "}
            <br />
            <Link
              href="/privacy-policy"
              className="text-neutral-200 hover:underline hover:text-neutral-50"
            >
              privacy
            </Link>
            {" | "}
            <Link
              href="/terms"
              className="text-neutral-200 hover:underline hover:text-neutral-50"
            >
              terms
            </Link>
            {" | "}
            <ConsentPreferences className="text-neutral-200 hover:underline hover:text-neutral-50" />
            {" | "}
            <Link
              href="https://app.termly.io/notify/1aa082a3-aba1-4169-b69b-c1d1b42b7a48"
              className="text-neutral-200 hover:underline hover:text-neutral-50"
            >
              do not sell or share my personal information
            </Link>
          </div>
          <div className="flex p-2 items-center justify-center space-x-5">
            <AppleIcon
              className="text-neutral-200 hover:text-neutral-50"
              size={5}
              href="/kb/client-apps/macos-client"
            />
            <WindowsIcon
              className="text-neutral-200 hover:text-neutral-50"
              size={5}
              href="/kb/client-apps/windows-client"
            />
            <LinuxIcon
              className="text-neutral-200 hover:text-neutral-50"
              size={5}
              href="/kb/client-apps/linux-gui-client"
            />
            <AndroidIcon
              className="text-neutral-200 hover:text-neutral-50"
              size={5}
              href="/kb/client-apps/android-client"
            />
          </div>
          <div className="flex p-2 items-center justify-center sm:justify-end space-x-5">
            <Link
              target="_blank"
              href={new URL("https://firezone.statuspage.io")}
              className="text-neutral-200 hover:underline hover:text-neutral-50 text-xs"
            >
              Platform status
            </Link>
            <XIcon
              className="text-neutral-200 hover:text-neutral-50"
              url={new URL("https://x.com/firezonehq")}
            />
            <GitHubIcon
              className="text-neutral-200 hover:text-neutral-50"
              url={new URL("https://github.com/firezone")}
            />
            <LinkedInIcon
              className="text-neutral-200 hover:text-neutral-50"
              url={new URL("https://linkedin.com/company/firezonehq")}
            />
          </div>
        </div>
      </div>
    </footer>
  );
}
