import { Metadata } from "next";
import CodeBlock from "@/components/CodeBlock";
import Link from "next/link";
import Image from "next/image";
import ActionLink from "@/components/ActionLink";
import {
  HiArrowLongRight,
  HiCheck,
  HiShieldCheck,
  HiHome,
  HiRocketLaunch,
  HiWrenchScrewdriver,
  HiGlobeAlt,
} from "react-icons/hi2";

export const metadata: Metadata = {
  title: "WireGuard® for Enterprise • Firezone",
  description: "Open-source, zero-trust access platform built on WireGuard®",
};

export default function Page() {
  return (
    <>
      <section className="bg-gradient-to-b from-primary-50 to-neutral-100 pt-24">
        <div className="px-4 py-8 mx-auto max-w-screen-xl text-center lg:py-16 lg:px-12">
          <h1 className="mb-4 md:text-6xl text-5xl justify-center font-extrabold tracking-tight leading-none text-neutral-900">
            Blazing-fast alternative to legacy VPNs
          </h1>
          <h2 className="mb-8 text-xl tracking-tight text-neutral-800 sm:px-16 xl:px-48">
            Manage secure remote access to your company’s most valuable services
            and resources with Firezone. We’re open source, and built on
            WireGuard®, a modern protocol that’s up to 4-6x faster than OpenVPN.
          </h2>
          <div className="flex mb-8 lg:mb-16 flex-row justify-center space-y-0 space-x-4">
            <Link href="/contact/sales">
              <button
                type="button"
                className="inline-flex shadow-lg justify-center items-center py-3 px-5 text-base font-bold text-center text-white rounded bg-gradient-to-br from-accent-700 to-accent-600 hover:scale-105 duration-0 transform transition"
              >
                Request demo
                <HiArrowLongRight className="ml-2 -mr-1 w-6 h-6" />
              </button>
            </Link>
          </div>
          <div className="flex items-center justify-center">
            <video
              className="shadow-lg rounded"
              width="960"
              height="540"
              loop
              autoPlay
              playsInline
              muted
            >
              <source src="/images/overview-screencap.webm" type="video/webm" />
              Your browser does not support the video tag with WebM-formatted
              videos.
            </video>
          </div>
          <div className="flex justify-center items-center p-8 mt-8">
            <h3 className="text-2xl tracking-tight font-bold text-neutral-800 ">
              Trusted by organizations like
            </h3>
          </div>
          <div className="gap-8 max-w-screen-xl grid justify-items-center sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-6 px-16 py-8">
            <Image
              alt="bunq logo"
              src="/images/bunq-logo.png"
              width={100}
              height={55}
            />
            <Image
              alt="tribe logo"
              src="/images/tribe-logo.png"
              width={100}
              height={55}
            />
            <Image
              alt="wolfram logo"
              src="/images/wolfram-logo.png"
              width={100}
              height={55}
            />
            <Image
              alt="rebank logo"
              src="/images/rebank-logo.png"
              width={100}
              height={55}
            />
            <Image
              alt="square1 logo"
              src="/images/square1-logo.png"
              width={100}
              height={55}
            />
            <Image
              alt="db11 logo"
              src="/images/db11-logo.png"
              width={100}
              height={55}
            />
          </div>
        </div>
      </section>

      {/* Features sections */}
      <section className="border-t border-neutral-200 bg-gradient-to-b from-white via-neutral-50 to-white py-24">
        <div className="mx-4 flex flex-col justify-center items-center">
          <h2 className="text-center justify-center mb-4 text-4xl tracking-tight font-bold text-neutral-900 ">
            Least-privileged access to your most valuable resources in just a
            few minutes.
          </h2>
        </div>

        {/* Feature section 1 */}
        <div className="gap-8 items-center py-8 px-4 mx-auto max-w-screen-xl lg:grid lg:grid-cols-2 xl:gap-16 sm:py-16 lg:px-6 ">
          <div>
            <h4 className="mb-8 text-lg font-semibold tracking-tight text-primary-450 ">
              EFFORTLESS SETUP
            </h4>
            <p className="text-xl text-neutral-800 my-4">
              Replace your legacy VPN with a modern zero trust solution.
              Firezone supports the workflows you're already familiar with, so
              you can get started in minutes and incrementally adopt zero trust
              over time.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Create a site
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Add one or more gateways
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Connect a resource or service
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Choose which user groups can access each resource
                </span>
              </li>
            </ul>
          </div>
          <Image
            width={600}
            height={500}
            alt="Feature 1"
            src="/images/feature-1.png"
          />
        </div>

        {/* Feature section 2 */}
        <div className="gap-8 py-8 px-4 mx-auto max-w-screen-xl flex flex-col-reverse lg:grid lg:grid-cols-2 xl:gap-16 sm:py-16 lg:px-6 ">
          <div className="flex flex-col">
            <Image
              className="rounded shadow-md"
              width={600}
              height={500}
              alt="Feature 2"
              src="/images/feature-2.png"
            />
            <Link
              className="mt-4 lg:mx-auto text-accent-600 hover:underline"
              href="https://core.ac.uk/download/pdf/322886318.pdf"
            >
              Performance comparison of VPN solutions (Osswald et al.)
            </Link>
          </div>
          <div>
            <h4 className="mb-8 text-lg font-semibold tracking-tight text-primary-450 ">
              RELIABLE ACCESS
            </h4>
            <p className="text-xl text-neutral-800 my-4">
              Firezone is fast and dependable which means your team is always
              connected to the resources they need most. It works on all major
              platforms and stays connected even when switching networks.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Automatic NAT traversal
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Global relay network
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Automatic gateway failover and load balancing
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Native clients for all major platforms
                </span>
              </li>
            </ul>
          </div>
        </div>

        {/* Feature section 3 */}
        <div className="gap-8 items-center pt-8 px-4 mx-auto max-w-screen-xl lg:grid lg:grid-cols-2 xl:gap-16 sm:pt-16 lg:px-6 ">
          <div>
            <h4 className="mb-8 text-lg font-semibold tracking-tight text-primary-450 ">
              MAINTAIN CONTROL
            </h4>
            <p className="text-xl text-neutral-800 my-4">
              Firezone establishes secure, end-to-end encrypted tunnels between
              your users and gateways, then gets out of the way. Gateways are
              deployed on your infrastructure, so you maintain full control over
              your data at all times.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Deploy gateways as Docker containers or standalone binaries
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Connect VPC, data center, on-prem, and cloud resources
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Customize resource-level access policies
                </span>
              </li>
            </ul>
            <ActionLink
              className="inline-flex items-center text-accent-600 hover:underline text-lg mt-8"
              href="/docs/deploy"
            >
              Explore the deployment docs
            </ActionLink>
          </div>
          <Image
            className="rounded shadow-md"
            width={600}
            height={500}
            alt="Feature 3"
            src="/images/feature-3.png"
          />
        </div>
      </section>

      <section className="border-t border-neutral-200 bg-gradient-to-b from-neutral-100 to-primary-50 py-24">
        <div className="mx-4 flex flex-col justify-center items-center">
          <h2 className="mb-4 text-4xl justify-center text-center tracking-tight font-bold text-neutral-900 ">
            Next-Gen security
          </h2>
          <h3 className="my-4 text-xl tracking-tight max-w-screen-lg text-center text-neutral-800 ">
            Firezone is built from the ground up with modern security best
            practices in mind.
          </h3>
          <ul
            role="list"
            className="max-w-screen-sm mt-6 mb-8 space-y-4 text-lg"
          >
            <li className="flex space-x-5">
              <HiShieldCheck className="text-accent-600 flex-shrink-0 w-7 h-7" />
              <p>
                <strong>Resource-level access policies</strong> that update in{" "}
                <strong className="text-primary-500">real-time</strong> based on
                changes from your identity provider.
              </p>
            </li>
            <li className="flex space-x-5">
              <HiShieldCheck className="text-accent-600 flex-shrink-0 w-7 h-7" />
              <p>
                <strong>NAT hole punching</strong> means{" "}
                <strong className="text-primary-500">no</strong> exposed attack
                surface and <strong className="text-primary-500">zero</strong>{" "}
                firewall configuration required.
              </p>
            </li>
            <li className="flex space-x-5">
              <HiShieldCheck className="text-accent-600 flex-shrink-0 w-7 h-7" />
              <p>
                <strong>Self-hosted gateways</strong> and configurable routing
                rules ensure data-plane traffic passes{" "}
                <strong className="text-primary-500">only</strong> through your
                infrastructure.
              </p>
            </li>
          </ul>
        </div>
        <div className="mx-4 flex flex-col justify-center items-center">
          <h2 className="mb-4 text-4xl justify-center text-center tracking-tight font-bold text-neutral-900 ">
            That works <span className="text-primary-500">with</span> your
            identity provider
          </h2>
        </div>
        <div className="mx-auto gap-8 max-w-screen-xl grid justify-items-center sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-6 px-16 pt-8">
          <Link href="/docs/authenticate/oidc/keycloak/">
            <Image
              width={150}
              height={75}
              alt="keycloak logo"
              src="/images/keycloak-logo.png"
            />
          </Link>
          <Link href="/docs/authenticate/oidc/google/">
            <Image
              width={150}
              height={75}
              alt="google logo"
              src="/images/google-logo.png"
            />
          </Link>
          <Link href="/docs/authenticate/oidc/okta/">
            <Image
              width={150}
              height={75}
              alt="okta logo"
              src="/images/okta-logo.png"
            />
          </Link>
          <Link href="/docs/authenticate/oidc/onelogin/">
            <Image
              width={150}
              height={75}
              alt="onelogin logo"
              src="/images/onelogin-logo.png"
            />
          </Link>
          <Link href="/docs/authenticate/oidc/azuread/">
            <Image
              width={150}
              height={75}
              alt="azure logo"
              src="/images/azure-logo.png"
            />
          </Link>
          <Link href="/docs/authenticate/saml/jumpcloud/">
            <Image
              width={150}
              height={75}
              alt="jumpcloud logo"
              src="/images/jumpcloud-logo.png"
            />
          </Link>
        </div>
      </section>

      <section className="border-t border-neutral-200 py-24 bg-white">
        <div className="mx-4 flex flex-col justify-center items-center">
          <h2 className="mb-4 justify-center text-center text-4xl tracking-tight font-bold text-neutral-900 ">
            How customers are using Firezone
          </h2>
        </div>
        <div className="gap-4 items-center pt-8 px-4 mx-auto max-w-screen-xl lg:grid lg:grid-cols-2 xl:gap-8 sm:pt-16 lg:px-6 ">
          <div className="bg-neutral-100 p-8 rounded shadow-md">
            <div className="flex items-center space-x-2.5">
              <HiHome className="flex-shrink-0 w-5 h-5 text-primary-450" />
              <h3 className="text-xl tracking-tight font-bold text-neutral-900 ">
                VPN Replacement
              </h3>
            </div>
            <p className="mt-8 text-neutral-900 text-xl">
              Remote employees can securely access office networks, cloud VPCs,
              and other private subnets and resources from anywhere in the
              world, on any device.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Easy to use, no training required
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Authenticate with virtually any identity provider
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Highly available gateways
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Modern encryption and authentication
                </span>
              </li>
            </ul>
          </div>
          <div className="bg-neutral-100 p-8 rounded shadow-md">
            <div className="flex items-center space-x-2.5">
              <HiRocketLaunch className="flex-shrink-0 w-5 h-5 text-primary-450" />
              <h3 className="text-xl tracking-tight font-bold text-neutral-900 ">
                Infrastructure Access
              </h3>
            </div>
            <p className="mt-8 text-neutral-900 text-xl">
              Empower engineers and DevOps to manage their team’s access to
              technical resources like test/prod servers both on-prem, and in
              the cloud.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Admin REST API
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Multiple admins per account
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Docker and Terraform integrations
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Automatically sync users and groups from your IdP
                </span>
              </li>
            </ul>
          </div>
          <div className="bg-neutral-100 p-8 rounded shadow-md">
            <div className="flex items-center space-x-2.5">
              <HiGlobeAlt className=" lex-shrink-0 w-5 h-5 text-primary-450" />
              <h3 className="text-xl tracking-tight font-bold text-neutral-900 ">
                Internet Security
              </h3>
            </div>
            <p className="mt-8 text-neutral-900 text-xl">
              Route sensitive internet traffic through a trusted gateway to keep
              remote employees more secure, even when they’re traveling or using
              public WiFi.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Native clients for all major platforms
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Enforce MFA / 2FA
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Filter malicious or unwanted DNS requests
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Monitor and audit authorized connections
                </span>
              </li>
            </ul>
          </div>
          <div className="bg-neutral-100 p-8 rounded shadow-md">
            <div className="flex items-center space-x-2.5">
              <HiWrenchScrewdriver className=" lex-shrink-0 w-5 h-5 text-primary-450" />
              <h3 className="text-xl tracking-tight font-bold text-neutral-900 ">
                Homelab Access
              </h3>
            </div>
            <p className="mt-8 text-neutral-900 text-xl">
              Securely access your home network, and services like Plex,
              security cameras, a Raspberry Pi, and other self-hosted apps when
              you’re away from home.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Easy to setup and simple to manage
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Reliable NAT traversal
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Invite friends and family to your private network
                </span>
              </li>
            </ul>
          </div>
        </div>
      </section>
    </>
  );
}
