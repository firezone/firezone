"use client";

import Toggle from "@/components/Toggle";
import Link from "next/link";
import { useState } from "react";
import { FaCheck, FaCircleCheck } from "react-icons/fa6";

export default function PricingTiers() {
  const [annual, setAnnual] = useState(true);

  return (
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
          <ul role="list" className="text-sm md:text-md font-medium space-y-4">
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
        <div className="p-8 md:p-6 lg:p-8 xl:p-10 bg-white rounded-xl shadow-light mb-4">
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
              <span className="font-medium text-sm text-neutral-700 inline-block align-bottom ml-1 mb-1">
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

          <ul role="list" className="text-sm md:text-md font-medium space-y-4">
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
        <div className="p-8 md:p-6 lg:p-8 xl:p-10 bg-neutral-950 text-neutral-50 rounded-xl shadow-light mb-4">
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
  );
}
