import CodeBlock from "@/components/CodeBlock";
import Link from "next/link";
import Image from "next/image";
import ActionLink from "@/components/ActionLink";
import CustomerLogos from "@/components/CustomerLogos";
import {
  HiFingerPrint,
  HiArrowLongRight,
  HiCheck,
  HiShieldCheck,
  HiHome,
  HiRocketLaunch,
  HiWrenchScrewdriver,
  HiGlobeAlt,
} from "react-icons/hi2";

export default function Page() {
  return (
    <>
      <section className="bg-neutral-100 pt-24">
        <div className="px-4 py-8 mx-auto max-w-screen-xl text-center lg:py-16 lg:px-12">
          <h1 className="mb-4 md:text-6xl text-5xl justify-center font-extrabold tracking-tight leading-none text-neutral-900">
            Blazing-fast alternative to legacy VPNs
          </h1>
          <h2 className="mb-8 text-xl tracking-tight text-neutral-800 sm:px-16 xl:px-48">
            Manage secure remote access to your company’s most valuable services
            and resources with Firezone. We’re open source, and built on
            WireGuard®, a modern protocol that’s up to 4-6x faster than
            OpenVPN.
          </h2>
          <div className="flex mb-8 lg:mb-16 flex-row justify-center space-y-0 space-x-4">
            <Link href="/contact/sales">
              <button
                type="button"
                className="inline-flex shadow-lg justify-center items-center py-3 px-5 text-base font-bold text-center text-white rounded bg-accent-450 hover:bg-accent-700 hover:scale-105 duration-0 transform transition"
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
          <CustomerLogos />
        </div>
      </section>

      {/* Features sections */}
      <section className="border-t border-neutral-200 bg-white py-24">
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
                  Create a{" "}
                  <Link
                    className="text-accent-500 underline hover:no-underline"
                    href="/kb/deploy/sites?utm_source=website"
                  >
                    site
                  </Link>
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Deploy one or more{" "}
                  <Link
                    className="text-accent-500 underline hover:no-underline"
                    href="/kb/deploy/gateways?utm_source=website"
                  >
                    gateways
                  </Link>
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Add a{" "}
                  <Link
                    className="text-accent-500 underline hover:no-underline"
                    href="/kb/deploy/resources?utm_source=website"
                  >
                    resource
                  </Link>{" "}
                  (e.g. subnet, host or service)
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900 font-bold " />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Choose which{" "}
                  <Link
                    className="text-accent-500 underline hover:no-underline"
                    href="/kb/authenticate?utm_source=website"
                  >
                    user groups
                  </Link>{" "}
                  have access
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
              width={600}
              height={500}
              alt="Feature 2"
              src="/images/feature-2.png"
            />
          </div>
          <div>
            <h4 className="mb-8 text-lg font-semibold tracking-tight text-primary-450 ">
              RELIABLE ACCESS
            </h4>
            <p className="text-xl text-neutral-800 my-4">
              Firezone is fast and dependable so your team is always connected
              to the resources they need most. It works on all major platforms
              and stays connected even when switching WiFi networks.
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
              Firezone establishes secure, direct tunnels between your users and
              gateways, then gets out of the way. Gateways are deployed on your
              infrastructure, so you retain full control over your data at all
              times.
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
                  Enforce direct connections between users and resources
                </span>
              </li>
            </ul>
          </div>
          <Image
            width={600}
            height={500}
            alt="Feature 3"
            src="/images/feature-3.png"
          />
        </div>
      </section>

      <section className="border-t border-neutral-200 bg-neutral-100 py-24">
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
                <strong className="text-primary-450">real-time</strong> based on
                changes from your IdP.
              </p>
            </li>
            <li className="flex space-x-5">
              <HiShieldCheck className="text-accent-600 flex-shrink-0 w-7 h-7" />
              <p>
                <strong>NAT hole punching</strong> means{" "}
                <strong className="text-primary-450">no</strong> exposed attack
                surface and <strong className="text-primary-450">zero</strong>{" "}
                firewall configuration required.
              </p>
            </li>
            <li className="flex space-x-5">
              <HiShieldCheck className="text-accent-600 flex-shrink-0 w-7 h-7" />
              <p>
                <strong>Self-hosted gateways</strong> and configurable routing
                rules ensure data-plane traffic passes{" "}
                <strong className="text-primary-450">only</strong> through your
                infrastructure.
              </p>
            </li>
          </ul>
        </div>
        <div className="mx-4 mb-8 flex flex-col justify-center items-center">
          <h2 className="inline-block mb-4 text-4xl justify-center text-center tracking-tight font-bold text-neutral-900 ">
            That works <span className="text-primary-450">with</span> your IdP
          </h2>
          <div className="mx-auto gap-4 max-w-screen-md grid justify-items-center sm:grid-cols-2 pt-8 px-8">
            <div className="text-center">
              <Image
                width={96}
                height={96}
                className="mx-auto mb-4"
                alt="fingerprint icon"
                src="/images/fingerprint.svg"
              />
              <h3 className="justify-center text-xl tracking-tight font-bold text-neutral-900 ">
                Enforce 2FA / MFA
              </h3>
              <p className="mt-4 text-neutral-900 text-lg">
                Add SSO with any OIDC-compatible identity provider (IdP) to
                limit connections to current and authenticated users only.
              </p>
            </div>
            <div className="text-center">
              <Image
                width={96}
                height={96}
                className="mx-auto mb-4"
                alt="user group sync icon"
                src="/images/user-group-sync.svg"
              />
              <h3 className="justify-center text-xl tracking-tight font-bold text-neutral-900 ">
                Sync users & groups<sup className="text-xs">*</sup>
              </h3>
              <p className="mt-4 text-neutral-900 text-lg">
                Sync IdP users and groups to ensure active employees can access
                your network, and revoke access when employees leave.
              </p>
              <p className="mt-2 text-neutral-900 text-xs">
                * Currently available for Google Workspace
              </p>
            </div>
          </div>
        </div>
        <div className="mx-auto gap-8 max-w-screen-xl grid justify-items-center sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-6 px-16 pt-8">
          <Link href="/docs/authenticate/oidc/keycloak">
            <Image
              width={150}
              height={75}
              alt="keycloak logo"
              src="/images/keycloak-logo.png"
            />
          </Link>
          <Link href="/docs/authenticate/oidc/google">
            <Image
              width={150}
              height={75}
              alt="google logo"
              src="/images/google-logo.png"
            />
          </Link>
          <Link href="/docs/authenticate/oidc/okta">
            <Image
              width={150}
              height={75}
              alt="okta logo"
              src="/images/okta-logo.png"
            />
          </Link>
          <Link href="/docs/authenticate/oidc/onelogin">
            <Image
              width={150}
              height={75}
              alt="onelogin logo"
              src="/images/onelogin-logo.png"
            />
          </Link>
          <Link href="/docs/authenticate/oidc/azuread">
            <Image
              width={150}
              height={75}
              alt="azure logo"
              src="/images/azure-logo.png"
            />
          </Link>
          <Link href="/docs/authenticate/saml/jumpcloud">
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
        <div className="gap-4 items-center pt-8 px-4 mx-auto max-w-screen-xl md:grid md:grid-cols-2 xl:gap-8 sm:pt-16 lg:px-6 ">
          <div className="bg-neutral-100 p-8 border border-neutral-200">
            <div className="flex items-center space-x-2.5">
              <HiShieldCheck className=" lex-shrink-0 w-6 h-6 text-accent-600" />
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
                  Authenticate with virtually any IdP
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
          <div className="bg-neutral-100 p-8 border border-neutral-200">
            <div className="flex items-center space-x-2.5">
              <HiRocketLaunch className="flex-shrink-0 w-6 h-6 text-accent-600" />
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
          <div className="bg-neutral-100 p-8 border border-neutral-200">
            <div className="flex items-center space-x-2.5">
              <HiGlobeAlt className=" lex-shrink-0 w-6 h-6 text-accent-600" />
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
          <div className="bg-neutral-100 p-8 border border-neutral-200">
            <div className="flex items-center space-x-2.5">
              <HiHome className="flex-shrink-0 w-6 h-6 text-accent-600" />
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
                  Authenticate with Magic link or OIDC
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

      <section className="border-t border-neutral-200 py-24 bg-neutral-900">
        <div className="flex flex-col px-4 justify-center items-center">
          <h2 className="mb-4 text-4xl tracking-tight text-center font-bold text-neutral-50">
            Ready to get started?
          </h2>
          <h3 className="my-4 font-medium text-xl max-w-screen-md tracking-tight text-center text-neutral-200 ">
            Give your team secure access to company resources in minutes.
          </h3>
          <div className="w-full max-w-screen-sm flex justify-between mt-8">
            <button
              type="button"
              className="w-64 inline-flex shadow-lg justify-center items-center py-3 px-5 text-base font-semibold text-center text-neutral-900 rounded bg-neutral-50 hover:scale-105 duration-0 transform transition"
            >
              <Link href="/product/early-access">
                Register for early access
              </Link>
            </button>
            <button
              type="button"
              className="w-64 inline-flex shadow-lg justify-center items-center py-3 px-5 text-base font-bold text-center text-white rounded bg-primary-450 hover:scale-105 duration-0 transform transition"
            >
              <Link href="/contact/sales">Request demo</Link>
              <HiArrowLongRight className="ml-2 -mr-1 w-6 h-6" />
            </button>
          </div>
        </div>
      </section>
    </>
  );
}
