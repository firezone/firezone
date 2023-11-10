import Link from "next/link";
import Image from "next/image";
import ConsentPreferences from "@/components/ConsentPreferences";

import { LinkedInIcon, GitHubIcon, TwitterIcon } from "@/components/Icons";

export default function Footer() {
  return (
    <footer className="relative bg-white border-t">
      <div className="mx-auto w-full max-w-screen-xl p-4 py-6 lg:py-8">
        <div className="md:flex md:justify-between">
          <div className="mb-6 md:mb-0">
            <Link href="/">
              <Image
                width={150}
                height={150}
                src="/images/logo-text.svg"
                className="h-auto"
                alt="Firezone Logo"
              />
            </Link>
          </div>
          <div className="grid grid-cols-2 gap-8 sm:gap-6 sm:grid-cols-3">
            <div>
              <h2 className="mb-6 text-sm font-semibold text-neutral-900 uppercase ">
                Company
              </h2>
              <ul className="text-neutral-900  font-medium">
                <li className="mb-4">
                  <Link href="/" className="hover:underline">
                    Home
                  </Link>
                </li>
                <li className="mb-4">
                  <Link href="/blog" className="hover:underline">
                    Blog
                  </Link>
                </li>
                <li className="mb-4">
                  <Link href="/team" className="hover:underline">
                    Team
                  </Link>
                </li>
                <li>
                  <Link
                    href="https://www.ycombinator.com/companies/firezone"
                    className="hover:underline"
                  >
                    Jobs
                  </Link>
                </li>
              </ul>
            </div>
            <div>
              <h2 className="mb-6 text-sm font-semibold text-neutral-900 uppercase ">
                Resources
              </h2>
              <ul className="text-neutral-900  font-medium">
                <li className="mb-4">
                  <Link
                    href="/docs"
                    className="hover:underline hover:text-neutral-900"
                  >
                    Docs
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="/product/early-access"
                    className="hover:underline hover:text-neutral-900"
                  >
                    Early Access
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="/product/roadmap"
                    className="hover:underline hover:text-neutral-900"
                  >
                    Roadmap
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="/contact/sales"
                    className="hover:underline hover:text-neutral-900"
                  >
                    Sales
                  </Link>
                </li>
                <li>
                  <Link
                    href="/product/newsletter"
                    className="hover:underline hover:text-neutral-900"
                  >
                    Newsletter
                  </Link>
                </li>
              </ul>
            </div>
            <div>
              <h2 className="mb-6 text-sm font-semibold text-neutral-900 uppercase ">
                Community
              </h2>
              <ul className="text-neutral-900  font-medium">
                <li className="mb-4">
                  <Link
                    href="https://discourse.firez.one"
                    className="hover:underline hover:text-neutral-900"
                  >
                    Forums
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="https://join.slack.com/t/firezone-users/shared_invite/zt-19jd956j4-rWcCqiKMh~ikPGsUFbvZiA"
                    className="hover:underline hover:text-neutral-900"
                  >
                    Slack
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="https://github.com/firezone"
                    className="hover:underline hover:text-neutral-900"
                  >
                    GitHub
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="https://twitter.com/firezonehq"
                    className="hover:underline hover:text-neutral-900"
                  >
                    Twitter
                  </Link>
                </li>
                <li>
                  <Link
                    href="https://www.linkedin.com/company/firezonehq"
                    className="hover:underline hover:text-neutral-900"
                  >
                    LinkedIn
                  </Link>
                </li>
              </ul>
            </div>
          </div>
        </div>
        <div className="sm:flex sm:items-center sm:justify-start mt-4">
          <span className="text-xs">
            WireGuard® is a registered trademark of Jason A. Donenfeld.
          </span>
        </div>
        <div className="sm:flex sm:items-center sm:justify-start lg:mt-2">
          <span className="text-xs">
            Firezone<sup>™</sup> is a registered trademark of Firezone, Inc.
          </span>
        </div>
        <hr className="mt-2 mb-2 border-neutral-200 sm:mx-auto lg:mb-8 lg:mt-4" />
        <div className="sm:flex sm:items-center sm:justify-between">
          <span className="text-xs text-neutral-900 sm:text-center ">
            © 2023{" "}
            <Link href="/" className="hover:underline">
              Firezone, Inc.
            </Link>{" "}
            <Link href="/privacy-policy" className="hover:underline">
              privacy
            </Link>
            {" | "}
            <Link href="/terms" className="hover:underline">
              terms
            </Link>
            {" | "}
            <ConsentPreferences />
            {" | "}
            <Link
              href="https://app.termly.io/notify/1aa082a3-aba1-4169-b69b-c1d1b42b7a48"
              className="hover:underline"
            >
              do not sell or share my personal information
            </Link>
          </span>
          <div className="flex mt-4 space-x-6 sm:justify-center sm:mt-0">
            <TwitterIcon url="https://twitter.com/firezonehq" />
            <GitHubIcon url="https://github.com/firezone" />
            <LinkedInIcon url="https://linkedin.com/comppany/firezonehq" />
          </div>
        </div>
      </div>
    </footer>
  );
}
