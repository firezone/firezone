import { Metadata } from "next";
import CodeBlock from "@/components/CodeBlock";
import Link from "next/link";
import Image from "next/image";
import ActionLink from "@/components/ActionLink";
import {
  ArrowLongRightIcon,
  CheckIcon,
  HomeIcon,
  RocketLaunchIcon,
  WrenchScrewdriverIcon,
  GlobeAltIcon,
} from "@heroicons/react/24/solid";
import JoinOurCommunity from "@/components/JoinOurCommunity";

export const metadata: Metadata = {
  title: "Open-source Remote Access • Firezone",
  description: "Open-source remote access built on WireGuard®.",
};

export default function Page() {
  return (
    <>
      <section className="bg-neutral-100 pt-24 ">
        <div className="px-4 py-8 mx-auto max-w-screen-xl sm:text-center lg:py-16 lg:px-12">
          <h1 className="mb-4 md:text-6xl text-5xl justify-center font-extrabold tracking-tight leading-none text-neutral-900">
            Fast, effortless secure access.
          </h1>
          <p className="mb-8 text-xl font-medium text-neutral-900 sm:px-16 xl:px-48 ">
            Firezone is an open-source remote access platform built on
            WireGuard®, a modern VPN protocol that's 4-6x faster than OpenVPN.
            Deploy on your infrastructure and start onboarding users in minutes.
          </p>
          <div className="flex flex-col mb-8 lg:mb-16 space-y-4 sm:flex-row sm:justify-center sm:space-y-0 sm:space-x-4">
            <Link href="/docs/deploy">
              <button
                type="button"
                className="inline-flex shadow-lg justify-center items-center py-3 px-5 text-base font-bold text-center text-white rounded-md bg-gradient-to-br from-accent-700 to-accent-600 hover:scale-105 duration-0 transform transition"
              >
                Deploy now
                <ArrowLongRightIcon className="ml-2 -mr-1 w-6 h-6" />
              </button>
            </Link>
          </div>
          <div className="flex items-center justify-center">
            <video
              className="shadow-lg rounded-md"
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
            <h3 className="text-2xl font-bold text-neutral-800 ">
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
              alt="poughkeepsie logo"
              src="/images/poughkeepsie-logo.png"
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
          <h2 className="justify-center mb-4 text-4xl tracking-tight font-bold text-neutral-900 ">
            A modern alternative to legacy VPNs
          </h2>
        </div>

        {/* Feature section 1 */}
        <div className="gap-8 items-center py-8 px-4 mx-auto max-w-screen-xl lg:grid lg:grid-cols-2 xl:gap-16 sm:py-16 lg:px-6 ">
          <div>
            <h4 className="mb-8 text-lg font-semibold tracking-tight text-primary-450 ">
              SIMPLE TO MANAGE
            </h4>
            <h3 className="text-2xl font-semibold tracking-tight text-neutral-900">
              Streamline workflows.
              <br />
              Reduce total cost of ownership.
            </h3>
            <p className="text-xl text-neutral-800 my-4">
              Legacy VPNs are cumbersome to manage and take weeks to configure
              correctly. Firezone takes minutes to deploy and the Web GUI makes
              managing secure access effortless for admins.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Integrate any identity provider to enforce 2FA / MFA
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Define user-scoped access rules
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Manage access with a snappy admin dashboard
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
              className="rounded-md shadow-md"
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
              FAST AND LIGHTWEIGHT
            </h4>
            <h3 className="text-2xl font-semibold tracking-tight text-neutral-900">
              High throughput and low latency. <br />
              Up to 4-6x faster than OpenVPN.
            </h3>
            <p className="text-xl text-neutral-800 my-4">
              Increase productivity and decrease connection issues for your
              remote team. Firezone uses kernel WireGuard® to be efficient,
              reliable, and performant in any environment.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  <Link
                    className="text-accent-600 hover:underline"
                    href="https://www.wireguard.com/protocol/"
                  >
                    State-of-the-art cryptography
                  </Link>
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Auditable and{" "}
                  <Link
                    className="text-accent-600 hover:underline"
                    href="https://www.wireguard.com/formal-verification/"
                  >
                    formally verified
                  </Link>
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  <Link
                    className="text-accent-600 hover:underline"
                    href="https://www.wireguard.com/performance/"
                  >
                    Multi-threaded
                  </Link>{" "}
                  performance that scales
                </span>
              </li>
            </ul>
          </div>
        </div>

        {/* Feature section 3 */}
        <div className="gap-8 items-center pt-8 px-4 mx-auto max-w-screen-xl lg:grid lg:grid-cols-2 xl:gap-16 sm:pt-16 lg:px-6 ">
          <div>
            <h4 className="mb-8 text-lg font-semibold tracking-tight text-primary-450 ">
              RUN ANYWHERE
            </h4>
            <h3 className="text-2xl font-semibold tracking-tight text-neutral-900">
              Firezone runs entirely on your infrastructure. <br />
              No vendor lock-in.
            </h3>
            <p className="text-xl text-neutral-800 my-4">
              Deploy Firezone on any platform that supports Docker. There's no
              need to risk breaches by sending data to third parties.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  VPC, data center, or on-prem
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Auto-renewing SSL certs from Let's Encrypt via ACME
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Flexible and configurable
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
            className="rounded-md shadow-md"
            width={600}
            height={500}
            alt="Feature 3"
            src="/images/feature-3.png"
          />
        </div>
      </section>

      <section className="border-t border-neutral-200 bg-gradient-to-b from-neutral-100 to-primary-50 py-24">
        <div className="mx-4 flex flex-col justify-center items-center">
          <h2 className="mb-4 text-4xl tracking-tight font-bold text-neutral-900 ">
            Integrate your identity provider to enforce 2FA / MFA
          </h2>
          <p className="my-4 text-xl max-w-screen-lg text-center text-primary-900 ">
            Only allow connections from authenticated users and automatically
            disable access for employees who have left. Firezone integrates with
            any OIDC and SAML 2.0 compatible identity provider for single
            sign-on (SSO).
          </p>
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
          <h2 className="mb-4 text-4xl tracking-tight font-bold text-neutral-900 ">
            Who can benefit using Firezone?
          </h2>
          <p className="my-4 text-xl max-w-screen-lg sm:text-center text-primary-900 ">
            Easy to deploy and manage for individuals and organizations alike.
            Only allow connections from authenticated users and automatically
            disable access for employees who have left. Firezone integrates with
            any OIDC and SAML 2.0 compatible identity provider for single
            sign-on (SSO).
          </p>
        </div>
        <div className="gap-4 items-center pt-8 px-4 mx-auto max-w-screen-xl lg:grid lg:grid-cols-2 xl:gap-8 sm:pt-16 lg:px-6 ">
          <div className="bg-neutral-100 p-8 rounded-md shadow-md">
            <div className="flex items-center space-x-2.5">
              <HomeIcon className="flex-shrink-0 w-5 h-5 text-primary-450" />
              <h3 className="text-xl tracking-tight font-bold text-primary-900 ">
                Individuals and homelab users
              </h3>
            </div>
            <p className="mt-8 text-primary-900 text-xl">
              Lightweight and fast. Access your home network securely when on
              the road.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Effortless to deploy on any infrastructure
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Community plan supports unlimited devices
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Lightweight with minimal resource usage
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Open-source and self-hosted
                </span>
              </li>
            </ul>
            <ActionLink
              className="inline-flex items-center text-accent-600 hover:underline text-lg mt-8"
              href="/docs"
            >
              Access your personal project
            </ActionLink>
          </div>
          <div className="bg-neutral-100 p-8 rounded-md shadow-md">
            <div className="flex items-center space-x-2.5">
              <RocketLaunchIcon className="flex-shrink-0 w-5 h-5 text-primary-450" />
              <h3 className="text-xl tracking-tight font-bold text-primary-900 ">
                Growing businesses
              </h3>
            </div>
            <p className="mt-8 text-primary-900 text-xl">
              Keep up with increasing network and compliance demands as you
              scale your team and infrastructure.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Integrate your identity provider
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Quickly onboard/offboard employees{" "}
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Segment access for contractors
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  High performance, reduce bottlenecks
                </span>
              </li>
            </ul>
            <ActionLink
              className="inline-flex items-center text-accent-600 hover:underline text-lg mt-8"
              href="/docs"
            >
              Scale your secure access
            </ActionLink>
          </div>
          <div className="bg-neutral-100 p-8 rounded-md shadow-md">
            <div className="flex items-center space-x-2.5">
              <GlobeAltIcon className=" lex-shrink-0 w-5 h-5 text-primary-450" />
              <h3 className="text-xl tracking-tight font-bold text-primary-900 ">
                Remote organizations
              </h3>
            </div>
            <p className="mt-8 text-primary-900 text-xl">
              Transitioning to remote? Perfect timing to replace the legacy VPN.
              Improve your security posture and reduce support tickets.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Require periodic re-authentication
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Enforce MFA / 2FA
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Self-serve user portal
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Export logs to your observability platform
                </span>
              </li>
            </ul>
            <ActionLink
              className="inline-flex items-center text-accent-600 hover:underline text-lg mt-8"
              href="/docs"
            >
              Secure your remote workforce
            </ActionLink>
          </div>
          <div className="bg-neutral-100 p-8 rounded-md shadow-md">
            <div className="flex items-center space-x-2.5">
              <WrenchScrewdriverIcon className=" lex-shrink-0 w-5 h-5 text-primary-450" />
              <h3 className="text-xl tracking-tight font-bold text-primary-900 ">
                Technical IT teams
              </h3>
            </div>
            <p className="mt-8 text-primary-900 text-xl">
              Firezone runs on your infrastructure. Customize it to suit your
              needs and architecture.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Built on WireGuard®
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  No vendor lock-in
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Supports OIDC and SAML 2.0
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-900 font-bold " />
                <span className="leading-tight text-lg text-primary-900 ">
                  Flexible and configurable
                </span>
              </li>
            </ul>
            <ActionLink
              className="inline-flex items-center text-accent-600 hover:underline text-lg mt-8"
              href="/docs"
            >
              Explore the documentation
            </ActionLink>
          </div>
        </div>
      </section>

      <JoinOurCommunity />

      <section className="border-t border-neutral-200 py-24 bg-gradient-to-b from-accent-800 to-accent-700">
        <div className="flex flex-col justify-center items-center">
          <h2 className="mb-4 text-4xl tracking-tight font-bold text-neutral-50 ">
            Ready to get started?
          </h2>
          <p className="my-4 font-semibold text-xl max-w-screen-md text-center text-neutral-200 ">
            Set up secure access and start onboarding users in minutes.
            <br />
            Copy and paste the command below on any Docker-supported host.
          </p>
          <div className="mt-8">
            <CodeBlock
              language="bash"
              codeString="bash <(curl -fsSL https://github.com/firezone/firezone/raw/legacy/scripts/install.sh)"
            />
          </div>
          <p className="mt-8 border-y font-semibold text-xl w-12 max-w-screen-md text-center text-neutral-200 ">
            OR
          </p>
          <div className="flex mt-8">
            <button
              type="button"
              className="inline-flex shadow-lg justify-center items-center py-3 px-5 text-base font-bold text-center text-white rounded-md bg-gradient-to-br from-primary-500 to-primary-450 hover:scale-105 duration-0 transform transition"
            >
              <Link href="/contact/sales">Contact sales</Link>
              <ArrowLongRightIcon className="ml-2 -mr-1 w-6 h-6" />
            </button>
          </div>
        </div>
      </section>
    </>
  );
}
