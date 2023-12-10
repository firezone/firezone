import EarlyAccessForm from "@/components/EarlyAccessForm";
import Link from "next/link";
import Image from "next/image";
import { Metadata } from "next";
import { HiCheckCircle } from "react-icons/hi2";
import ActionLink from "@/components/ActionLink";

export const metadata: Metadata = {
  title: "Early Access • Firezone",
  description:
    "Register for early access to try new Firezone features before they're released.",
};

export default function EarlyAccess() {
  return (
    <div className="pt-14 bg-neutral-100">
      <div className="py-8 px-4 mx-auto max-w-screen-2xl lg:py-16 lg:px-6">
        <div className="grid flex gap-4 lg:grid-cols-2">
          <div className="flex items-center justify-center lg:justify-start">
            <div className="flex-wrap px-2">
              <h1 className="mb-4 text-5xl sm:text-6xl text-center justify-center lg:justify-end font-extrabold tracking-tight text-neutral-900 xl:text-6xl">
                Request early access
              </h1>
              <h2 className="flex flex-wrap mb-4 text-lg tracking-tight text-neutral-800 sm:text-xl justify-center lg:justify-end">
                <strong className="mr-1">Firezone 1.0 is coming!</strong>
                <span className="font-medium">
                  Sign up below to get early access.
                </span>
              </h2>
              <p className="text-lg sm:text-xl lg:justify-end">
                <ActionLink
                  href="/blog/firezone-1-0"
                  className="mb-8 justify-center lg:justify-end flex items-center text-accent-500 hover:no-underline underline"
                >
                  Read the announcement
                </ActionLink>
              </p>
            </div>
          </div>
          <div className="flex flex-row-reverse items-baseline space-x-reverse -space-x-8">
            <span className="z-0">
              <Image
                src="/images/portal_mockup.svg"
                className="shadow-lg rounded"
                height={500}
                width={800}
                alt="firezone portal mockup"
              />
            </span>
            <span className="z-10">
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
      </div>
      <section className="bg-white border-t border-neutral-200 pb-14">
        <div className="mx-auto lg:max-w-screen-lg max-w-screen-sm">
          <div className="py-14 mx-auto">
            <h2 className="justify-center mb-8 sm:mb-16 text-2xl font-extrabold tracking-tight text-neutral-900 sm:text-4xl">
              1.0 Timeline
            </h2>
            <ol className="px-4 items-center sm:flex">
              <li className="relative mb-6 sm:mb-0">
                <div className="flex items-center">
                  <div className="z-10 flex items-center justify-center font-semibold w-6 h-6 bg-neutral-300 text-neutral-900 rounded-full ring-0 ring-accent-600 ring-8 shrink-0">
                    1
                  </div>
                  <div className="hidden sm:flex w-full bg-accent-600 h-1"></div>
                </div>
                <div className="mt-3 sm:pr-8">
                  <h3 className="text-lg font-semibold text-neutral-900">
                    Announcement
                  </h3>
                  <time className="block mb-2 text-sm font-normal leading-none text-neutral-700">
                    Q3 2023
                  </time>
                  <p className="text-base font-normal text-neutral-800">
                    Firezone 1.0 is announced to the public. Early access
                    signups open.
                  </p>
                </div>
              </li>
              <li className="relative mb-6 sm:mb-0">
                <div className="flex items-center">
                  <div className="z-10 flex items-center justify-center font-semibold w-6 h-6 bg-neutral-300 text-neutral-900 rounded-full ring-0 ring-accent-600 ring-8 shrink-0">
                    2
                  </div>
                  <div className="hidden sm:flex w-full bg-neutral-300 h-0.5"></div>
                </div>
                <div className="mt-3 sm:pr-8">
                  <h3 className="text-lg font-semibold text-neutral-900">
                    Beta Testing
                  </h3>
                  <time className="block mb-2 text-sm font-normal leading-none text-neutral-700">
                    Q4 2023
                  </time>
                  <p className="text-base font-normal text-neutral-800">
                    Early access users are invited to beta test the 1.0 release.
                  </p>
                </div>
              </li>
              <li className="relative mb-6 sm:mb-0">
                <div className="flex items-center">
                  <div className="z-10 flex items-center font-semibold justify-center w-6 h-6 text-neutral-900 bg-white rounded-full ring-0 ring-neutral-300 ring-8 shrink-0">
                    3
                  </div>
                  <div className="hidden sm:flex w-full bg-neutral-300 h-0.5"></div>
                </div>
                <div className="mt-3 sm:pr-8">
                  <h3 className="text-lg font-semibold text-neutral-900">
                    Public Release
                  </h3>
                  <time className="block mb-2 text-sm font-normal leading-none text-neutral-700">
                    Q1 2024
                  </time>
                  <p className="text-base font-normal text-neutral-800">
                    Firezone 1.0 is released to the general public.
                  </p>
                </div>
              </li>
            </ol>
          </div>
          <div className="pt-14 mx-auto max-w-screen-lg">
            <h2 className="justify-center mb-8 text-2xl font-extrabold tracking-tight text-neutral-900 sm:text-4xl">
              Join our early access program
            </h2>
          </div>
          <EarlyAccessForm />
        </div>
      </section>
    </div>
  );
}
