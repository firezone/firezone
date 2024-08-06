"use client";

import Link from "next/link";
import Image from "next/image";
import { Accordion } from "flowbite-react";
import { manrope } from "@/lib/fonts";
import type { CustomFlowbiteTheme } from "flowbite-react";
import { HiMiniShieldCheck } from "react-icons/hi2";

export default function ElevatorPitch() {
  return (
    <div className="flex flex-col max-w-[600px]">
      <h6 className="uppercase text-md font-semibold text-primary-450 tracking-wide mb-4">
        Stay Connected
      </h6>
      <div className="sm:mx-auto mb-4 text-4xl md:text-6xl text-pretty text-left ">
        <h3 className=" tracking-tight font-bold inline-block">
          Supercharge your workforce in{" "}
          <span className="text-primary-450">minutes</span>.
        </h3>
      </div>
      <div className="max-w-screen-md">
        <p className="text-lg text-left tracking-tight text-pretty text-slate-500">
          Protect your workforce without the tedious configuration.
        </p>
      </div>
      <div className="mt-16">
        <Accordion
          className="divide-y-0 border-none"
          id="accordion-color"
          data-accordion="collapse"
          data-active-classes="bg-blue-100 dark:bg-gray-800 text-blue-600 dark:text-white"
        >
          <Accordion.Panel>
            <Accordion.Title className="bg-transparent hover:bg-primary-50 focus:ring-1 focus:ring-primary-450">
              <HiMiniShieldCheck size={24} className="mr-2 text-primary-400" />
              Built on WireGuard.
            </Accordion.Title>
            <Accordion.Content>
              <p className="mb-2 text-gray-500 dark:text-gray-400">
                Flowbite is an open-source library of interactive components
                built on top of Tailwind CSS including buttons, dropdowns,
                modals, navbars, and more.
              </p>
              <p className="text-gray-500 dark:text-gray-400">
                Check out this guide to learn how to&nbsp;
                <a
                  href="https://flowbite.com/docs/getting-started/introduction/"
                  className="text-cyan-600 hover:underline dark:text-cyan-500"
                >
                  get started&nbsp;
                </a>
                and start developing websites even faster with components on top
                of Tailwind CSS.
              </p>
            </Accordion.Content>
          </Accordion.Panel>
          <Accordion.Panel>
            <Accordion.Title>Scales with your business.</Accordion.Title>
            <Accordion.Content>
              <p className="mb-2 text-gray-500 dark:text-gray-400">
                Flowbite is first conceptualized and designed using the Figma
                software so everything you see in the library has a design
                equivalent in our Figma file.
              </p>
              <p className="text-gray-500 dark:text-gray-400">
                Check out the
                <a
                  href="https://flowbite.com/figma/"
                  className="text-cyan-600 hover:underline dark:text-cyan-500"
                >
                  Figma design system
                </a>
                based on the utility classes from Tailwind CSS and components
                from Flowbite.
              </p>
            </Accordion.Content>
          </Accordion.Panel>
          <Accordion.Panel>
            <Accordion.Title>Zero attack surface.</Accordion.Title>
            <Accordion.Content>
              <p className="mb-2 text-gray-500 dark:text-gray-400">
                The main difference is that the core components from Flowbite
                are open source under the MIT license, whereas Tailwind UI is a
                paid product. Another difference is that Flowbite relies on
                smaller and standalone components, whereas Tailwind UI offers
                sections of pages.
              </p>
              <p className="mb-2 text-gray-500 dark:text-gray-400">
                However, we actually recommend using both Flowbite, Flowbite
                Pro, and even Tailwind UI as there is no technical reason
                stopping you from using the best of two worlds.
              </p>
              <p className="mb-2 text-gray-500 dark:text-gray-400">
                Learn more about these technologies:
              </p>
              <ul className="list-disc pl-5 text-gray-500 dark:text-gray-400">
                <li>
                  <a
                    href="https://flowbite.com/pro/"
                    className="text-cyan-600 hover:underline dark:text-cyan-500"
                  >
                    Flowbite Pro
                  </a>
                </li>
                <li>
                  <a
                    href="https://tailwindui.com/"
                    rel="nofollow"
                    className="text-cyan-600 hover:underline dark:text-cyan-500"
                  >
                    Tailwind UI
                  </a>
                </li>
              </ul>
            </Accordion.Content>
          </Accordion.Panel>
        </Accordion>
      </div>
    </div>
  );
}
