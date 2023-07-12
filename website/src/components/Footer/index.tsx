import Link from "next/link";
import Image from "next/image";

import { LinkedInIcon, GitHubIcon, TwitterIcon } from "@/components/Icons";

export default function Footer() {
  return (
    <footer className="relative bg-white dark:bg-neutral-900 border-t">
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
              <h2 className="mb-6 text-sm font-semibold text-neutral-900 uppercase dark:text-white">
                Company
              </h2>
              <ul className="text-neutral-800 dark:text-neutral-100 font-medium">
                <li className="mb-4">
                  <Link href="/" className="hover:underline">
                    Home
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
              <h2 className="mb-6 text-sm font-semibold text-neutral-900 uppercase dark:text-white">
                Resources
              </h2>
              <ul className="text-neutral-800 dark:text-neutral-100 font-medium">
                <li className="mb-4">
                  <Link href="/docs" className="hover:underline">
                    Docs
                  </Link>
                </li>
                <li className="mb-4">
                  <Link href="/blog" className="hover:underline">
                    Blog
                  </Link>
                </li>
                <li className="mb-4">
                  <Link href="/contact/sales" className="hover:underline">
                    Contact
                  </Link>
                </li>
                <li>
                  <Link href="/contact/newsletter" className="hover:underline">
                    Newsletter
                  </Link>
                </li>
              </ul>
            </div>
            <div>
              <h2 className="mb-6 text-sm font-semibold text-neutral-900 uppercase dark:text-white">
                Community
              </h2>
              <ul className="text-neutral-800 dark:text-neutral-100 font-medium">
                <li className="mb-4">
                  <Link
                    href="https://discourse.firez.one"
                    className="hover:underline"
                  >
                    Forums
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="https://join.slack.com/t/firezone-users/shared_invite/zt-19jd956j4-rWcCqiKMh~ikPGsUFbvZiA"
                    className="hover:underline"
                  >
                    Slack
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="https://github.com/firezone"
                    className="hover:underline"
                  >
                    GitHub
                  </Link>
                </li>
                <li className="mb-4">
                  <Link
                    href="https://twitter.com/firezonehq"
                    className="hover:underline"
                  >
                    Twitter
                  </Link>
                </li>
                <li>
                  <Link
                    href="https://www.linkedin.com/company/firezonehq"
                    className="hover:underline"
                  >
                    LinkedIn
                  </Link>
                </li>
              </ul>
            </div>
          </div>
        </div>
        <hr className="my-6 border-neutral-200 sm:mx-auto dark:border-neutral-700 lg:my-8" />
        <div className="sm:flex sm:items-center sm:justify-between">
          <span className="text-sm text-neutral-800 sm:text-center dark:text-neutral-100">
            © 2023{" "}
            <Link href="/" className="hover:underline">
              Firezone, Inc.
            </Link>{" "}
            All Rights Reserved.
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
