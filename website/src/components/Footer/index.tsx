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
    <footer className="pt-12 relative bg-neutral-900 text-neutral-500">
      <div className="mx-auto w-full max-w-screen-xl p-4 py-6 lg:py-8">
        <div className="grid md:grid-cols-3 gap-12">
          <div className="flex md:flex-col justify-between">
            <Link href="/">
              <Image
                width={150}
                height={150}
                src="/images/logo-text-dark.svg"
                alt="Firezone Logo"
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
            <Link href="https://trust.firezone.dev">
              <Image
                alt="SOC2 badge"
                width={75}
                height={75}
                src="/images/soc2.svg"
              />
            </Link>
          </div>
          <div className="flex flex-col justify-center text-center">
            <h3 className="text-neutral-200 mb-4 text-3xl md:text-4xl tracking-tight justify-center font-semibold">
              Ready to get started?
            </h3>
            <h4 className="text-neutral-200 text-md tracking-tight justify-center">
              Give your organization the security it deserves.
            </h4>
            <div className="w-full flex flex-wrap justify-between mt-8">
              <div className="mb-8 mx-auto">
                <button
                  type="button"
                  className="text-md w-48 inline-flex justify-center items-center py-3 px-5 font-semibold text-center text-primary-450 rounded border border-primary-450 bg-neutral-100 hover:ring-2 hover:ring-primary-400 duration-50 transform transition"
                >
                  <Link href="https://app.firezone.dev/sign_up">
                    Sign up now
                  </Link>
                </button>
                <p className="mt-3 text-xs text-neutral-400">
                  No credit card required. Cancel anytime.
                </p>
              </div>
              <div className="mx-auto">
                <button
                  type="button"
                  className="text-md w-48 inline-flex shadow-lg justify-center items-center py-3 px-5 font-semibold text-center text-white rounded bg-primary-450 hover:ring-2 hover:ring-primary-500 duration-50 transform transition"
                >
                  <Link href="/contact/sales">Book a demo</Link>
                  <HiArrowLongRight className="ml-2 -mr-1 w-6 h-6" />
                </button>
                <p className="mt-3 text-xs text-neutral-400">
                  Get a personalized walkthrough of Firezone.
                </p>
              </div>
            </div>
          </div>
          <div className="text-sm grid grid-cols-2 content-end md:text-right">
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
