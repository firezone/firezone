"use client";

import { CustomerLogosColored } from "@/components/CustomerLogos";
import Toggle from "@/components/Toggle";
import Link from "next/link";
import PlanTable from "./plan_table";
import { useState } from "react";
import {
  Accordion,
  AccordionPanel,
  AccordionTitle,
  AccordionContent,
} from "flowbite-react";
import { FaCheck, FaCircleCheck } from "react-icons/fa6";

export default function Page() {
  const [annual, setAnnual] = useState(true);

  return (
    <>
      <section className="bg-neutral-100 pb-14">
        <div className="text-center">
          <div className="flex gap-4 justify-center ps-6 mb-2.5">
            <span
              className={
                (annual
                  ? "text-neutral-500 font-medium text-md"
                  : "text-neutral-900 font-semibold text-lg") +
                "text-left uppercase"
              }
            >
              Monthly
            </span>
            <Toggle checked={annual} onChange={setAnnual} />
            <span
              className={
                (annual
                  ? "text-neutral-900 font-semibold text-lg"
                  : "text-neutral-500 font-medium text-md") +
                "text-left uppercase"
              }
            >
              Annual
              <span className="ml-2 text-sm text-accent-600 font-semibold">
                Save 17%
              </span>
            </span>
          </div>
        </div>

        <div className="mx-auto bg-neutral-100 max-w-screen-2xl md:grid md:grid-cols-3 pt-10 md:gap-2 lg:gap-4 px-4">
          <div className="p-8 md:p-6 lg:p-8 xl:p-10 bg-white rounded-xl shadow-light mb-4">
            <h3 className="mb-6 text-xl tracking-tight font-semibold text-neutral-900">
              Starter
            </h3>
            <h2 className="mb-6 text-2xl sm:text-4xl tracking-tight font-bold text-neutral-900">
              Free
            </h2>
            <p className="mb-8 text-sm text-neutral-600">
              Secure remote access for individuals and small groups.
            </p>
            <div className="mb-2 w-full text-center">
              <Link href="https://app.firezone.dev/sign_up">
                <button
                  type="button"
                  className="bg-neutral-100 w-full text-lg px-5 py-2.5 md:text-sm md:px-3 md:py-2.5 lg:text-lg lg:px-5 lg:py-2.5 border
                  border border-neutral-500  hover:brightness-90 font-semibold tracking-tight rounded-full text-neutral-950 duration-50 transition transform"
                >
                  Sign up
                </button>
              </Link>
            </div>
            <p className="text-sm text-center text-neutral-600 mb-8">
              No credit card required.
            </p>
            <ul
              role="list"
              className="text-sm md:text-md font-medium space-y-4"
            >
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 w-4 h-4 text-primary-450" />
                <span className="leading-tight text-neutral-900">
                  Up to 6 users
                </span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 w-4 h-4 text-primary-450" />
                <span className="leading-tight text-neutral-900">
                  Access your homelab or VPC from anywhere
                </span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 w-4 h-4 text-primary-450" />
                <span className="leading-tight text-neutral-900">
                  Native clients for Windows, Linux, macOS, iOS, Android
                </span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 w-4 h-4 text-primary-450" />
                <span className="leading-tight text-neutral-900">
                  Authenticate via email or OpenID Connect (OIDC)
                </span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 w-4 h-4 text-primary-450" />
                <span className="leading-tight text-neutral-900">
                  Load balancing and automatic failover
                </span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 w-4 h-4 text-primary-450" />
                <span className="leading-tight text-neutral-900">
                  No firewall configuration required
                </span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 w-4 h-4 text-primary-450" />
                <span className="leading-tight text-neutral-900">
                  Community Support
                </span>
              </li>
            </ul>
          </div>
          <div
            className={`p-8 md:p-6 lg:p-8 xl:p-10 bg-white rounded-xl shadow-light mb-4 font-manrope`}
          >
            <h3 className="mb-6 text-xl tracking-tight font-semibold text-neutral-900">
              Team
            </h3>

            <h2 className="mb-6 text-2xl sm:text-4xl tracking-tight font-bold text-neutral-900">
              {annual && (
                <>
                  <span className="line-through">$5</span>
                  <span className="text-primary-450">$4.16</span>
                </>
              )}
              {!annual && <span>$5</span>}
              <span className="h-full">
                <span className="font-medium text-sm text-neutral-700 inline-block align-bottom tracking-tight ml-1 mb-1">
                  {" "}
                  per user/month
                </span>
              </span>
            </h2>
            <p className="mb-8 text-sm text-neutral-600">
              Zero trust network access for teams and organizations
            </p>
            <div className="mb-10 w-full text-center">
              <Link href="https://app.firezone.dev/sign_up">
                <button
                  type="button"
                  className="bg-primary-450 w-full text-lg px-5 py-2.5 md:text-sm md:px-3 md:py-2.5 lg:text-lg lg:px-5 lg:py-2.5
                   hover:brightness-90 font-semibold tracking-tight rounded-full text-neutral-100 duration-50 transition transform"
                >
                  Sign up
                </button>
              </Link>
            </div>
            <p
              className={`${
                annual ? "hidden" : "block"
              } text-primary-450 font-semibold cursor-pointer text-center -mt-8 mb-8 text-sm`}
              onClick={() => {
                setAnnual(true);
              }}
            >
              Save 17% by switching to annual
            </p>

            <ul
              role="list"
              className="text-sm md:text-md font-medium space-y-4"
            >
              <li className="flex space-x-2.5">
                <FaCircleCheck className="shrink-0 w-4 h-4 text-accent-450" />
                <span className="leading-tight font-bold text-neutral-900 ">
                  Everything in Starter
                </span>
              </li>
              <div className="flex w-full gap-3 items-center">
                <div className="h-px w-full bg-neutral-300" />
                <p className="uppercase text-neutral-900 font-medium">plus</p>
                <div className="h-px w-full bg-neutral-300" />
              </div>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 w-4 h-4 text-primary-450" />
                <span className="leading-tight font-bold text-neutral-900">
                  Up to 500 users
                </span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 w-4 h-4 text-primary-450" />
                <span className="leading-tight text-neutral-900">
                  Resource access logs
                </span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 w-4 h-4 text-primary-450" />
                <span className="leading-tight text-neutral-900">
                  Port and protocol traffic restrictions
                </span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 w-4 h-4 text-primary-450" />
                <span className="leading-tight text-neutral-900">
                  Conditional access policies
                </span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 w-4 h-4 text-primary-450" />
                <span className="leading-tight text-neutral-900">
                  Customize your account slug
                </span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 w-4 h-4 text-primary-450" />
                <span className="leading-tight text-neutral-900">
                  Priority email support
                </span>
              </li>
            </ul>
          </div>
          <div
            className={`p-8 md:p-6 lg:p-8 xl:p-10 bg-neutral-950 text-neutral-50 rounded-xl shadow-light mb-4 font-manrope`}
          >
            <div className="mb-6 flex items-center justify-between">
              <h3 className="text-xl tracking-tight font-semibold text-neutral-50">
                Enterprise
              </h3>
              <span className="text-center font-bold w-fit uppercase text-xs rounded-full bg-neutral-50 text-primary-450 px-3 py-1">
                30-day trial
              </span>
            </div>
            <h2 className="mb-6 text-2xl sm:text-4xl tracking-tight font-bold text-neutral-50">
              Contact us
            </h2>
            <p className="mb-8 text-sm text-neutral-400">
              Compliance-ready security for large organizations
            </p>
            <div className="mb-10 w-full text-center">
              <Link href="/contact/sales">
                <button
                  type="button"
                  className="bg-primary-450 w-full text-lg px-5 py-2.5 md:text-sm md:px-3 md:py-2.5 lg:text-lg lg:px-5 lg:py-2.5
                   hover:brightness-90 font-semibold tracking-tight rounded-full text-neutral-100 duration-50 transition transform"
                >
                  Request a demo
                </button>
              </Link>
            </div>

            <ul
              role="list"
              className="text-sm md:text-md font-medium space-y-4 text-neutral-300"
            >
              <li className="flex space-x-2.5">
                <FaCircleCheck className="shrink-0 w-4 h-4 text-accent-300" />
                <span className="leading-tight font-bold text-neutral-50">
                  Everything in Starter and Team
                </span>
              </li>
              <div className="flex w-full gap-3 items-center">
                <div className="h-px w-full bg-neutral-700" />
                <p className="uppercase text-neutral-50 font-medium">plus</p>
                <div className="h-px w-full bg-neutral-700" />
              </div>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 text-primary-450 w-4 h-4" />
                <span className="leading-tight font-bold text-neutral-50">
                  Unlimited users
                </span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 text-primary-450 w-4 h-4" />
                <span className="leading-tight">
                  Directory sync for Google, Entra ID, and Okta
                </span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 text-primary-450 w-4 h-4" />
                <span className="leading-tight">
                  Dedicated Slack support channel
                </span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 text-primary-450 w-4 h-4" />
                <span className="leading-tight">Uptime SLAs</span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 text-primary-450 w-4 h-4" />
                <span className="leading-tight">
                  Access to our SOC2 and pentest reports
                </span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 text-primary-450 w-4 h-4" />
                <span className="leading-tight">Roadmap acceleration</span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 text-primary-450 w-4 h-4" />
                <span className="leading-tight">White-glove onboarding</span>
              </li>
              <li className="flex space-x-2.5">
                <FaCheck className="mt-0.5 shrink-0 text-primary-450 w-4 h-4" />
                <span className="leading-tight">Annual invoicing</span>
              </li>
            </ul>
          </div>
        </div>
      </section>
      <section className="py-24 bg-gradient-to-b to-neutral-50 from-white">
        <CustomerLogosColored />
      </section>
      <section className="bg-neutral-50 py-14">
        <div className="mb-14 mx-auto max-w-screen-lg px-3">
          <h2 className="mb-14 justify-center text-4xl font-bold text-neutral-900">
            Compare plans
          </h2>
          <PlanTable />
        </div>
      </section>
      <section className="bg-neutral-100 border-t border-neutral-200 p-14">
        <div className="mx-auto max-w-screen-sm">
          <h2 className="mb-14 justify-center text-4xl font-bold text-neutral-900">
            FAQ
          </h2>

          <Accordion>
            <AccordionPanel>
              <AccordionTitle>
                How long does it take to set up Firezone?
              </AccordionTitle>
              <AccordionContent>
                A simple deployment takes{" "}
                <Link
                  href="/kb/quickstart"
                  className="hover:underline text-accent-500"
                >
                  less than 10 minutes{" "}
                </Link>
                and can be accomplished with by installing the{" "}
                <Link
                  href="/kb/client-apps"
                  className="hover:underline text-accent-500"
                >
                  Firezone Client
                </Link>{" "}
                and{" "}
                <Link
                  href="/kb/deploy/gateways"
                  className="hover:underline text-accent-500"
                >
                  deploying one or more Gateways
                </Link>
                .{" "}
                <Link href="/kb" className="hover:underline text-accent-500">
                  Visit our docs
                </Link>{" "}
                for more information and step by step instructions.
              </AccordionContent>
            </AccordionPanel>
            <AccordionPanel>
              <AccordionTitle>Is there a self-hosted plan?</AccordionTitle>
              <AccordionContent>
                All of the source code for the entire Firezone product is
                available at our{" "}
                <Link
                  href="https://www.github.com/firezone/firezone"
                  className="hover:underline text-accent-500"
                >
                  GitHub repository
                </Link>
                {
                  ", and you're free to self-host Firezone for your organization without restriction. However, we don't offer documentation or support for self-hosting Firezone at this time."
                }
              </AccordionContent>
            </AccordionPanel>
            <AccordionPanel>
              <AccordionTitle>
                Do I need to rip and replace my current VPN to use Firezone?
              </AccordionTitle>
              <AccordionContent>
                {
                  "No. As long they're set up to access different resources, you can run Firezone alongside your existing remote access solutions, and switch over whenever you're ready. There's no need for any downtime or unnecessary disruptions."
                }
              </AccordionContent>
            </AccordionPanel>
            <AccordionPanel>
              <AccordionTitle>
                Can I try Firezone before I buy it?
              </AccordionTitle>
              <AccordionContent>
                Yes. The Starter plan is free to use without limitation. No
                credit card is required to get started. The Enterprise plan
                includes a free pilot period to evaluate whether Firezone is a
                good fit for your organization.{" "}
                <Link
                  href="/contact/sales"
                  className="hover:underline text-accent-500"
                >
                  Contact sales
                </Link>{" "}
                to request a demo.
              </AccordionContent>
            </AccordionPanel>
            <AccordionPanel>
              <AccordionTitle>
                My seat counts have changed. Can I adjust my plan?
              </AccordionTitle>
              <AccordionContent>
                <p>Yes.</p>
                <p className="mt-2">
                  {"For the "}
                  <strong>Team</strong>
                  {
                    " plan, you can add or remove seats at any time. When adding seats, you'll be charged a prorated amount for the remainder of the billing cycle. When removing seats, the change will take effect at the end of the billing cycle."
                  }
                </p>
                <p className="mt-2">
                  {"For the "}
                  <strong>Enterprise</strong>
                  {
                    " plan, contact your account manager to request a seat increase. You'll then be billed for the prorated amount for the remainder of the billing cycle."
                  }
                </p>
              </AccordionContent>
            </AccordionPanel>
            <AccordionPanel>
              <AccordionTitle>
                What happens to my data with Firezone enabled?
              </AccordionTitle>
              <AccordionContent>
                Network traffic is always end-to-end encrypted, and by default,
                routes directly to Gateways running on your infrastructure. In
                rare circumstances, encrypted traffic can pass through our
                global relay network if a direct connection cannot be
                established. Firezone can never decrypt the contents of your
                traffic.
              </AccordionContent>
            </AccordionPanel>
            <AccordionPanel>
              <AccordionTitle>
                How do I cancel or change my plan?
              </AccordionTitle>
              <AccordionContent>
                For Starter and Team plans, you can downgrade by going to your
                Account settings in your Firezone admin portal. For Enterprise
                plans, contact your account manager for subscription updates. If
                {"you'd like to completely delete your account, "}
                <Link
                  href="mailto:support@firezone.dev"
                  className="hover:underline text-accent-500"
                >
                  contact support
                </Link>
                .
              </AccordionContent>
            </AccordionPanel>
            <AccordionPanel>
              <AccordionTitle>When will I be billed?</AccordionTitle>
              <AccordionContent>
                The Team plan is billed monthly on the same day you start
                service until canceled. Enterprise plans are billed annually.
              </AccordionContent>
            </AccordionPanel>
            <AccordionPanel>
              <AccordionTitle>
                What payment methods are available?
              </AccordionTitle>
              <AccordionContent>
                The Starter plan is free and does not require a credit card to
                get started. Team and Enterprise plans can be paid via credit
                card, ACH, or wire transfer.
              </AccordionContent>
            </AccordionPanel>
            <AccordionPanel>
              <AccordionTitle>
                Do you offer special pricing for nonprofits and educational
                institutions?
              </AccordionTitle>
              <AccordionContent>
                Yes. Not-for-profit organizations and educational institutions
                are eligible for a 50% discount.{" "}
                <Link
                  href="/contact/sales"
                  className="hover:underline text-accent-500"
                >
                  Contact sales
                </Link>{" "}
                to request the discount.
              </AccordionContent>
            </AccordionPanel>
            <AccordionPanel>
              <AccordionTitle>
                What payment methods are available?
              </AccordionTitle>
              <AccordionContent>
                The Starter plan is free and does not require a credit card to
                get started. Team and Enterprise plans can be paid via credit
                card, ACH, or wire transfer.
              </AccordionContent>
            </AccordionPanel>
          </Accordion>
        </div>
      </section>

      <section className="bg-neutral-100 border-t border-neutral-200 p-14">
        <div className="mx-auto max-w-screen-xl md:grid md:grid-cols-2">
          <div>
            <h2 className="w-full justify-center mb-8 text-2xl md:text-3xl font-semibold text-neutral-900">
              The WireGuard® solution for Enterprise.
            </h2>
          </div>
          <div className="mb-14 w-full text-center">
            <Link href="/contact/sales">
              <button
                type="button"
                className="w-64 text-white tracking-tight rounded-sm duration-50 hover:ring-2 hover:ring-primary-300 transition transform shadow-lg text-lg px-5 py-2.5 bg-primary-450 font-semibold"
              >
                Request a demo
              </button>
            </Link>
          </div>
        </div>
      </section>
    </>
  );
}
