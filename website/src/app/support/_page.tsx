"use client";

import Link from "next/link";
import KbSearch from "@/components/KbSearch";
import {
  HiOutlineBookOpen,
  HiOutlineServerStack,
  HiOutlineUserCircle,
  HiOutlineCommandLine,
  HiOutlineDocumentPlus,
  HiOutlineQuestionMarkCircle,
  HiOutlineMagnifyingGlass,
  HiOutlineMap,
  HiOutlineEnvelope,
} from "react-icons/hi2";
import { AiOutlineDiscord } from "react-icons/ai";
import { FaDiscourse } from "react-icons/fa";
import { FaSlack } from "react-icons/fa";

export default function _Page() {
  return (
    <div className="flex flex-col">
      {/* Knowledge base */}
      <section className="py-4 sm:py-6 md:py-8 lg:py-10 xl:py-12">
        <h2 className="tracking-tight text-2xl md:text-3xl lg:text-4xl font-semibold mb-4">
          <HiOutlineBookOpen className="w-8 h-8 mr-4" />
          Knowledge base
        </h2>
        <hr />
        <p className="text-md md:text-lg mt-8">
          Start here. Many questions can be answered by{" "}
          <Link href="/kb" className="text-accent-500 hover:underline">
            reading our docs
          </Link>
          .
        </p>
        <div className="mt-8 sm:w-1/2 sm:pr-4">
          <KbSearch buttonText="Search the knowledge base" />
        </div>
        <div className="mt-8 grid grid-cols-1 sm:grid-cols-2 gap-8">
          <Link
            href="/kb/deploy"
            className="p-6 hover:shadow-sm rounded-sm border-2 hover:border-accent-200 hover:bg-accent-50 transition duration-100"
          >
            <h3 className="text-neutral-800 text-lg font-semibold tracking-tight">
              <HiOutlineServerStack className="w-5 h-5 mr-2" />
              Deployment Guide
            </h3>
            <p className="mt-8">
              A detailed, step-by-step guide for users setting up Firezone for
              the first time. Read this guide to learn how to deploy a
              production-grade Firezone setup.
            </p>
          </Link>
          <Link
            href="/kb/client-apps"
            className="p-6 hover:shadow-sm rounded-sm border-2 hover:border-accent-200 hover:bg-accent-50 transition duration-100"
          >
            <h3 className="text-neutral-800 text-lg font-semibold tracking-tight">
              <HiOutlineUserCircle className="w-5 h-5 mr-2" />
              Client apps
            </h3>
            <p className="mt-8">
              Installation and usage instructions for the Firezone Clients
              designed to be consumed by your workforce.{" "}
            </p>
          </Link>
          <Link
            href="/kb/administer/troubleshooting"
            className="p-6 hover:shadow-sm rounded-sm border-2 hover:border-accent-200 hover:bg-accent-50 transition duration-100"
          >
            <h3 className="text-neutral-800 text-lg font-semibold tracking-tight">
              <HiOutlineCommandLine className="w-5 h-5 mr-2" />
              Troubleshooting guide
            </h3>
            <p className="mt-8">
              A comprehensive guide to help you troubleshoot common issues you
              may encounter using Firezone, including where to find logs and
              tips for debugging common issues.
            </p>
          </Link>
          <Link
            href="/kb/reference/faq"
            className="p-6 hover:shadow-sm rounded-sm border-2 hover:border-accent-200 hover:bg-accent-50 transition duration-100"
          >
            <h3 className="text-neutral-800 text-lg font-semibold tracking-tight">
              <HiOutlineQuestionMarkCircle className="w-5 h-5 mr-2" />
              FAQ
            </h3>
            <p className="mt-8">Some of our most frequently asked questions.</p>
          </Link>
        </div>
      </section>

      {/* GitHub */}
      <section className="py-4 sm:py-6 md:py-8 lg:py-10 xl:py-12">
        <h2 className="tracking-tight text-2xl md:text-3xl lg:text-4xl font-semibold mb-4">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            className="w-8 h-8 mr-4 box-border fill-current"
            viewBox="0 0 24 24"
          >
            <path
              fill="currentColor"
              d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.531 1.032 1.531 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.019 10.019 0 0022 12.017C22 6.484 17.522 2 12 2z"
            />
          </svg>
          <span className="sr-only">GitHub account</span>
          GitHub
        </h2>
        <hr />
        <p className="text-md md:text-lg mt-8">
          Didn&apos;t find what you were looking for? We build Firezone in the
          open -- there&apos;s a good chance someone&apos;s already opened an
          issue.
        </p>
        <div className="mt-8 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-8">
          <Link
            href="https://www.github.com/firezone/firezone/issues"
            className="p-6 hover:shadow-sm rounded-sm border-2 hover:border-accent-200 hover:bg-accent-50 transition duration-100"
          >
            <h3 className="text-neutral-800 text-lg font-semibold tracking-tight">
              <HiOutlineMagnifyingGlass className="w-5 h-5 mr-2" />
              Issue search
            </h3>
            <p className="mt-8">
              Search our open GitHub issues and leave a comment.
            </p>
          </Link>
          <Link
            href="https://github.com/orgs/firezone/projects/9"
            className="p-6 hover:shadow-sm rounded-sm border-2 hover:border-accent-200 hover:bg-accent-50 transition duration-100"
          >
            <h3 className="text-neutral-800 text-lg font-semibold tracking-tight">
              <HiOutlineMap className="w-5 h-5 mr-2" />
              Product roadmap
            </h3>
            <p className="mt-8">
              View our public roadmap for a glimpse into what we&apos;ve
              recently shipped and what&apos;s coming soon.
            </p>
          </Link>
          <Link
            href="/kb/administer/troubleshooting"
            className="p-6 hover:shadow-sm rounded-sm border-2 hover:border-accent-200 hover:bg-accent-50 transition duration-100"
          >
            <h3 className="text-neutral-800 text-lg font-semibold tracking-tight">
              <HiOutlineDocumentPlus className="w-5 h-5 mr-2" />
              Open an issue
            </h3>
            <p className="mt-8">
              Open a GitHub issue for feature requests, bug reports, and
              feedback.
            </p>
          </Link>
        </div>
      </section>

      {/* Contact */}
      <section className="py-4 sm:py-6 md:py-8 lg:py-10 xl:py-12">
        <h2 className="tracking-tight text-2xl md:text-3xl lg:text-4xl font-semibold mb-4">
          Still need help?
        </h2>
        <hr />
        <p className="text-md md:text-lg mt-8">
          Choose a support option below to get in touch with a Firezone team
          member.
        </p>
        <div className="mt-8 relative overflow-x-auto">
          <table className="w-full text-sm md:text-lg text-left text-neutral-700 font-medium">
            <thead className="text-xs md:text-sm text-neutral-800 uppercase bg-neutral-100">
              <tr>
                <th scope="col" className="px-6 py-3">
                  Option
                </th>
                <th scope="col" className="px-6 py-3">
                  Details
                </th>
                <th scope="col" className="px-6 py-3">
                  Wait time
                </th>
                <th scope="col" className="px-6 py-3">
                  Support hours
                </th>
              </tr>
            </thead>
            <tbody>
              {/* MOSTLY SPAM */}
              {/* <tr className="bg-white border-b"> */}
              {/*   <th */}
              {/*     scope="row" */}
              {/*     className="px-6 py-4 font-medium text-neutral-800" */}
              {/*   > */}
              {/*     <span className="flex items-center"> */}
              {/*       <HiOutlineChatBubbleOvalLeft className="w-5 h-5 mr-2" /> */}
              {/*       Live chat */}
              {/*     </span> */}
              {/*   </th> */}
              {/*   <td className="px-6 py-4"> */}
              {/*     <Link */}
              {/*       href="#" */}
              {/*       onClick={openChat} */}
              {/*       className="text-accent-500 hover:underline" */}
              {/*     > */}
              {/*       Start a chat */}
              {/*     </Link> */}
              {/*   </td> */}
              {/*   <td className="px-6 py-4">1 - 2 minutes</td> */}
              {/*   <td className="px-6 py-4">M-F 9:00a - 5:00p Pacific</td> */}
              {/* </tr> */}
              <tr className="bg-white border-b">
                <th
                  scope="row"
                  className="px-6 py-4 font-medium text-neutral-800"
                >
                  <span className="flex items-center">
                    <HiOutlineEnvelope className="w-5 h-5 mr-2" />
                    Email
                  </span>
                </th>
                <td className="px-6 py-4">
                  <Link
                    href="mailto:support@firezone.dev"
                    className="text-accent-500 hover:underline"
                  >
                    Send us an email
                  </Link>
                </td>
                <td className="px-6 py-4">1 - 2 business days</td>
                <td className="px-6 py-4">24/7</td>
              </tr>
              <tr className="bg-white border-b">
                <th
                  scope="row"
                  className="px-6 py-4 font-medium text-neutral-800"
                >
                  <span className="flex items-center">
                    <FaSlack className="w-5 h-5 mr-2" />
                    Dedicated Slack channel
                  </span>
                </th>
                <td className="px-6 py-4">
                  Available on Enterprise plans.{" "}
                  <Link
                    href="/contact/sales"
                    className="text-accent-500 hover:underline"
                  >
                    Contact sales
                  </Link>{" "}
                  for details.
                </td>
                <td className="px-6 py-4">Under 8 hours</td>
                <td className="px-6 py-4">M-F</td>
              </tr>
              <tr className="bg-white border-b">
                <th
                  scope="row"
                  className="px-6 py-4 font-medium text-neutral-800"
                >
                  <span className="flex items-center">
                    <AiOutlineDiscord className="w-5 h-5 mr-2" />
                    Community Discord
                  </span>
                </th>
                <td className="px-6 py-4" colSpan={3}>
                  <Link
                    href="https://discord.gg/P9RjyJMYK4"
                    className="text-accent-500 hover:underline"
                  >
                    Join our server
                  </Link>
                </td>
              </tr>
              <tr className="bg-white">
                <th
                  scope="row"
                  className="px-6 py-4 font-medium text-neutral-800"
                >
                  <span className="flex items-center">
                    <FaDiscourse className="w-5 h-5 mr-2" />
                    Community forums
                  </span>
                </th>
                <td className="px-6 py-4" colSpan={3}>
                  <Link
                    href="https://discourse.firez.one"
                    className="text-accent-500 hover:underline"
                  >
                    https://discourse.firez.one
                  </Link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}
