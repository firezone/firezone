import EarlyAccessForm from "@/components/EarlyAccessForm";
import Link from "next/link";
import Image from "next/image";
import { Metadata } from "next";
import { ArrowLongRightIcon, CheckCircleIcon } from "@heroicons/react/24/solid";

export const metadata: Metadata = {
  title: "1.0 Early Access • Firezone",
  description: "Get early access to Firezone 1.0.",
};

export default function EarlyAccess() {
  return (
    <div className="py-8 px-4 mx-auto lg:py-16 lg:px-6">
      <div className="grid flex grid-cols-1 gap-4 lg:grid-cols-2">
        <div className="flex items-center">
          <div className="flex-none">
            <h2 className="mb-4 text-4xl font-extrabold tracking-tight text-neutral-900 sm:text-6xl dark:text-white">
              Request early access
            </h2>
            <p className="mx-auto mb-4 text-neutral-800 sm:text-xl dark:text-neutral-100">
              <strong>Firezone 1.0 is coming! </strong>
              Sign up below to get early access.
            </p>
            <p className="text-right sm:text-xl dark:text-neutral-100">
              <Link
                href="/blog/announcing-1.0"
                className="text-accent-500 dark:text-accent-50 hover:no-underline underline"
              >
                Read the announcement
                <ArrowLongRightIcon className="inline-block ml-2 w-6 h-6" />
              </Link>
            </p>
          </div>
        </div>
        <div className="flex flex-row-reverse items-baseline space-x-reverse -space-x-8">
          <span>
            <Image
              src="/images/portal_mockup.svg"
              className="shadow-lg rounded-lg"
              height={500}
              width={800}
              alt="firezone portal mockup"
            />
          </span>
          <span>
            <Image
              src="/images/mobile_mockup.svg"
              className="shadow-lg rounded-2xl"
              height={220}
              width={125}
              alt="firezone mobile mockup"
            />
          </span>
        </div>
      </div>
      <div className="mx-auto max-w-screen-lg">
        <div className="py-12 sm:py-24 mx-auto">
          <h2 className="justify-center mb-8 sm:mb-16 text-2xl font-extrabold tracking-tight text-neutral-900 sm:text-4xl dark:text-neutral-50">
            1.0 Timeline
          </h2>
          <ol className="items-center sm:flex">
            <li className="relative mb-6 sm:mb-0">
              <div className="flex items-center">
                <div className="z-10 flex items-center justify-center font-semibold w-6 h-6 bg-accent-500 text-neutral-50 rounded-full ring-0 ring-white dark:bg-blue-900 sm:ring-8 dark:ring-neutral-900 shrink-0">
                  1
                </div>
                <div className="hidden sm:flex w-full bg-neutral-200 h-0.5 dark:bg-neutral-700"></div>
              </div>
              <div className="mt-3 sm:pr-8">
                <h3 className="text-lg font-semibold text-neutral-900 dark:text-white">
                  Announcement
                </h3>
                <time className="block mb-2 text-sm font-normal leading-none text-neutral-700 dark:text-neutral-300">
                  Early Q3 2023
                </time>
                <p className="text-base font-normal text-neutral-800 dark:text-neutral-200">
                  Firezone 1.0 is announced to the public. Early access signups
                  open.
                </p>
              </div>
            </li>
            <li className="relative mb-6 sm:mb-0">
              <div className="flex items-center">
                <div className="z-10 flex items-center font-semibold justify-center w-6 h-6 text-neutral-900 bg-neutral-200 rounded-full ring-0 ring-white dark:bg-blue-900 sm:ring-8 dark:ring-neutral-900 shrink-0">
                  2
                </div>
                <div className="hidden sm:flex w-full bg-neutral-200 h-0.5 dark:bg-neutral-700"></div>
              </div>
              <div className="mt-3 sm:pr-8">
                <h3 className="text-lg font-semibold text-neutral-900 dark:text-white">
                  Beta Testing
                </h3>
                <time className="block mb-2 text-sm font-normal leading-none text-neutral-700 dark:text-neutral-300">
                  Mid Q3 2023
                </time>
                <p className="text-base font-normal text-neutral-800 dark:text-neutral-200">
                  Early access users are invited to beta test the 1.0 release.
                </p>
              </div>
            </li>
            <li className="relative mb-6 sm:mb-0">
              <div className="flex items-center">
                <div className="z-10 flex items-center font-semibold justify-center w-6 h-6 text-neutral-900 bg-neutral-200 rounded-full ring-0 ring-white dark:bg-blue-900 sm:ring-8 dark:ring-neutral-900 shrink-0">
                  3
                </div>
                <div className="hidden sm:flex w-full bg-neutral-200 h-0.5 dark:bg-neutral-700"></div>
              </div>
              <div className="mt-3 sm:pr-8">
                <h3 className="text-lg font-semibold text-neutral-900 dark:text-white">
                  Public Release
                </h3>
                <time className="block mb-2 text-sm font-normal leading-none text-neutral-700 dark:text-neutral-300">
                  Late Q3 2023
                </time>
                <p className="text-base font-normal text-neutral-800 dark:text-neutral-200">
                  Firezone 1.0 is released to the general public.
                </p>
              </div>
            </li>
          </ol>
        </div>
        <EarlyAccessForm />
      </div>
    </div>
  );
}
