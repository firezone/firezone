import { Metadata } from "next";
import InstallBlock from "@/components/InstallBlock";
import Link from "next/link";
import Image from "next/image";
import { ArrowLongRightIcon, CheckIcon } from "@heroicons/react/24/solid";

export const metadata: Metadata = {
  title: "Open-source Remote Access • Firezone",
  description: "Open-source remote access built on WireGuard®.",
};

export default function Page() {
  return (
    <>
      <section className="bg-gray-50 pt-24 dark:bg-gray-900">
        <div className="px-4 py-8 mx-auto max-w-screen-xl text-center lg:py-16 lg:px-12">
          <h1 className="mb-4 text-4xl justify-center font-extrabold tracking-tight leading-none text-gray-900 md:text-5xl lg:text-6xl dark:text-white tracking-tight">
            Fast, effortless secure access.
          </h1>
          <p className="mb-8 font-normal text-gray-500 md:text-lg lg:text-xl sm:px-16 xl:px-48 dark:text-gray-400">
            Firezone is an open-source remote access platform built on
            WireGuard®, a modern VPN protocol that's 4-6x faster than OpenVPN.
            Deploy on your infrastructure and start onboarding users in minutes.
          </p>
          <div className="flex flex-col mb-8 lg:mb-16 space-y-4 sm:flex-row sm:justify-center sm:space-y-0 sm:space-x-4">
            <Link href="/docs/deploy">
              <button
                type="button"
                className="inline-flex shadow-lg justify-center items-center py-3 px-5 text-base font-bold text-center text-white rounded-lg focus:outline-none bg-gradient-to-r from-purple-500 via-purple-600 to-purple-700 hover:bg-gradient-to-br focus:ring-4 focus:ring-violet-300"
              >
                Deploy now
                <ArrowLongRightIcon className="ml-2 -mr-1 w-6 h-6" />
              </button>
            </Link>
          </div>
          <div className="flex items-center justify-center">
            <Image
              className="shadow-xl rounded-md"
              width={960}
              height={540}
              alt="overview screencap"
              src="/images/overview-screencap.gif"
            />
          </div>
          <div className="flex justify-center items-center p-8 mt-8">
            <h3 className="text-2xl font-bold text-gray-500 dark:text-white">
              Trusted by organizations like
            </h3>
          </div>
          <div className="flex justify-between items-center px-16 py-8">
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
      <section className="bg-white pt-24 dark:bg-gray-800">
        <div className="flex justify-center items-center">
          <h2 className="mb-4 text-4xl tracking-tight font-extrabold text-gray-900 dark:text-white">
            A modern alternative to legacy VPNs
          </h2>
        </div>

        {/* Feature section 1 */}
        <div className="gap-8 items-center py-8 px-4 mx-auto max-w-screen-xl lg:grid lg:grid-cols-2 xl:gap-16 sm:py-16 lg:px-6 ">
          <div>
            <h4 className="mb-8 text-lg font-semibold tracking-tight text-orange-500 dark:text-white">
              SIMPLE TO MANAGE
            </h4>
            <h3 className="text-2xl font-bold tracking-tight text-gray-900">
              Streamline workflows. Reduce total cost of ownership.
            </h3>
            <p className="text-lg text-gray-500 my-4">
              Legacy VPNs are cumbersome to manage and take weeks to configure
              correctly. Firezone takes minutes to deploy and the Web GUI makes
              managing secure access effortless for admins.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-600 font-bold dark:text-primary-500" />
                <span className="leading-tight text-lg text-primary-600 dark:text-gray-400">
                  Integrate any identity provider to enforce 2FA / MFA
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-600 font-bold dark:text-primary-500" />
                <span className="leading-tight text-lg text-primary-600 dark:text-gray-400">
                  Define user-scoped access rules
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-600 font-bold dark:text-primary-500" />
                <span className="leading-tight text-lg text-primary-600 dark:text-gray-400">
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
        <div className="gap-8 items-center py-8 px-4 mx-auto max-w-screen-xl lg:grid lg:grid-cols-2 xl:gap-16 sm:py-16 lg:px-6 ">
          <div className="flex flex-col justify-between">
            <Image
              className="rounded-md shadow-md"
              width={600}
              height={500}
              alt="Feature 2"
              src="/images/feature-2.png"
            />
            <Link
              className="mt-4 mx-auto text-violet-600 hover:underline"
              href="https://core.ac.uk/download/pdf/322886318.pdf"
            >
              Performance comparison of VPN solutions (Osswald et al.)
            </Link>
          </div>
          <div>
            <h4 className="mb-8 text-lg font-semibold tracking-tight text-orange-500 dark:text-white">
              FAST AND LIGHTWEIGHT
            </h4>
            <h3 className="text-2xl font-bold tracking-tight text-gray-900">
              High throughput and low latency. Up to 4-6x faster than OpenVPN.
            </h3>
            <p className="text-lg text-gray-500 my-4">
              Increase productivity and decrease connection issues for your
              remote team. Firezone uses kernel WireGuard® to be efficient,
              reliable, and performant in any environment.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-600 font-bold dark:text-primary-500" />
                <span className="leading-tight text-lg text-primary-600 dark:text-gray-400">
                  <Link
                    className="text-violet-600 hover:underline"
                    href="https://www.wireguard.com/protocol/"
                  >
                    State-of-the-art cryptography
                  </Link>
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-600 font-bold dark:text-primary-500" />
                <span className="leading-tight text-lg text-primary-600 dark:text-gray-400">
                  Auditable and{" "}
                  <Link
                    className="text-violet-600 hover:underline"
                    href="https://www.wireguard.com/formal-verification/"
                  >
                    formally verified
                  </Link>
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-600 font-bold dark:text-primary-500" />
                <span className="leading-tight text-lg text-primary-600 dark:text-gray-400">
                  <Link
                    className="text-violet-600 hover:underline"
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
        <div className="gap-8 items-center py-8 px-4 mx-auto max-w-screen-xl lg:grid lg:grid-cols-2 xl:gap-16 sm:py-16 lg:px-6 ">
          <div>
            <h4 className="mb-8 text-lg font-semibold tracking-tight text-orange-500 dark:text-white">
              RUN ANYWHERE
            </h4>
            <h3 className="text-2xl font-bold tracking-tight text-gray-900">
              Firezone runs entirely on your infrastructure. No vendor lock-in.
            </h3>
            <p className="text-lg text-gray-500 my-4">
              Deploy Firezone on any platform that supports Docker. There's no
              need to risk breaches by sending data to third parties.
            </p>
            <ul role="list" className="my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-600 font-bold dark:text-primary-500" />
                <span className="leading-tight text-lg text-primary-600 dark:text-gray-400">
                  VPC, data center, or on-prem
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-600 font-bold dark:text-primary-500" />
                <span className="leading-tight text-lg text-primary-600 dark:text-gray-400">
                  Auto-renewing SSL certs from Let's Encrypt via ACME
                </span>
              </li>
              <li className="flex space-x-2.5">
                <CheckIcon className="flex-shrink-0 w-5 h-5 text-primary-600 font-bold dark:text-primary-500" />
                <span className="leading-tight text-lg text-primary-600 dark:text-gray-400">
                  Flexible and configurable
                </span>
              </li>
            </ul>
            <Link
              className="inline-flex items-center text-violet-600 hover:underline text-lg mt-8"
              href="/docs/deploy"
            >
              Explore the deployment docs
              <ArrowLongRightIcon className="flex-shrink-0 w-5 h-5 ml-2" />
            </Link>
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

      <section className="bg-gray-50 pt-24 dark:bg-gray-800">
        <div className="flex flex-col justify-center items-center">
          <h2 className="mb-4 text-4xl tracking-tight font-extrabold text-gray-900 dark:text-white">
            Integrate your identity provider to enforce 2FA / MFA
          </h2>
          <p className="my-4 text-xl max-w-screen-lg text-center text-primary-600 dark:text-gray-400">
            Only allow connections from authenticated users and automatically
            disable access for employees who have left. Firezone integrates with
            any OIDC and SAML 2.0 compatible identity provider for single
            sign-on (SSO).
          </p>
        </div>
      </section>
    </>
  );
}

export function OldPage() {
  return (
    <div className="pt-24 flex flex-col">
      <div className="hero">
        <div className="container">
          <h1 className="hero__title">Fast, effortless secure access</h1>
          <p></p>
          <div className="row">
            <div className="col col--12">
              <center>
                <a className="button button--primary" href="/docs/deploy">
                  Deploy now
                </a>
              </center>
            </div>
          </div>
        </div>
      </div>

      <div className="container">
        <Image
          width={960}
          height={540}
          alt="overview screencap"
          src="/images/overview-screencap.gif"
        />
      </div>

      <hr className="margin-vert--xl" />

      <center>
        <h2 className="margin-bottom--lg">Trusted by organizations like</h2>
      </center>

      <div className="container">
        <div className="row">
          <div className="col col--2">
            <Image
              alt="bunq logo"
              src="/images/bunq-logo.png"
              width={100}
              height={55}
            />
          </div>
          <div className="col col--2">
            <Image
              alt="tribe logo"
              src="/images/tribe-logo.png"
              width={100}
              height={55}
            />
          </div>
          <div className="col col--2">
            <Image
              alt="poughkeepsie logo"
              src="/images/poughkeepsie-logo.png"
              width={100}
              height={55}
            />
          </div>
          <div className="col col--2">
            <Image
              alt="rebank logo"
              src="/images/rebank-logo.png"
              width={100}
              height={55}
            />
          </div>
          <div className="col col--2">
            <Image
              alt="square1 logo"
              src="/images/square1-logo.png"
              width={100}
              height={55}
            />
          </div>
          <div className="col col--2">
            <Image
              alt="db11 logo"
              src="/images/db11-logo.png"
              width={100}
              height={55}
            />
          </div>
        </div>
      </div>

      <hr className="margin-vert--xl" />

      <div className="hero">
        <div className="container">
          <h1 className="hero__title">An alternative to old VPNs</h1>
        </div>
      </div>

      {/* Feature 1 */}

      <div className="container">
        <center>
          <h2 className="margin-bottom--lg">
            Streamline workflows. Reduce total cost of ownership.
          </h2>
        </center>
      </div>
      <div className="container">
        <div className="row">
          <div className="col col--6">
            <p>
              Legacy VPNs are cumbersome to manage and take weeks to configure
              correctly. Firezone takes minutes to deploy and the Web GUI makes
              managing secure access effortless for admins.
            </p>
            <ul>
              <li>Integrate any identity provider to enforce 2FA / MFA</li>
              <li>Define user-scoped access rules</li>
              <li>Manage users with a snappy admin dashboard</li>
            </ul>
          </div>
          <div className="col col--6">
            <Image
              width={500}
              height={500}
              alt="Feature 1"
              src="/images/feature-1.png"
            />
          </div>
        </div>
      </div>

      <hr className="margin-vert--xl" />

      {/* Feature 2 */}

      <div className="container">
        <center>
          <h2 className="margin-bottom--lg">
            High throughput and low latency. Up to 4-6x faster than OpenVPN.
          </h2>
        </center>
      </div>
      <div className="container">
        <div className="row">
          <div className="col col--6">
            <Image
              width={500}
              height={500}
              alt="Feature 2"
              src="/images/feature-2.png"
            />
            <p>
              <Link href="https://core.ac.uk/download/pdf/322886318.pdf">
                Performance comparison of VPN solutions (Osswald et al.)
              </Link>
            </p>
          </div>
          <div className="col col--6">
            <p>
              Increase productivity and decrease connection issues for your
              remote team. Firezone uses kernel WireGuard® to be efficient,
              reliable, and performant in any environment.
            </p>
            <ul>
              <li>
                <Link href="https://www.wireguard.com/protocol/">
                  State-of-the-art cryptography
                </Link>
              </li>
              <li>
                <Link href="https://www.wireguard.com/formal-verification/">
                  Auditable and formally verified
                </Link>
              </li>
              <li>
                <Link href="https://www.wireguard.com/performance/">
                  Multi-threaded
                </Link>
              </li>
            </ul>
          </div>
        </div>
      </div>

      <hr className="margin-vert--xl" />

      {/* Feature 3 */}

      <div className="container">
        <center>
          <h2 className="margin-bottom--lg">
            Firezone runs entirely on your infrastructure. No vendor lock-in.
          </h2>
        </center>
      </div>
      <div className="container">
        <div className="row">
          <div className="col col--6">
            Deploy Firezone on any platform that supports Docker. There's no
            need to risk breaches by sending data to third parties.
            <ul>
              <li>VPC, data center, or on-prem</li>
              <li>Auto-renewing SSL certs from Let's Encrypt via ACME</li>
              <li>Flexible and configurable</li>
            </ul>
          </div>
          <div className="col col--6">
            <Image
              width={500}
              height={500}
              alt="Feature 3"
              src="/images/feature-3.png"
            />
            <Link href="/docs/deploy">
              Explore the deployment documentation &gt;
            </Link>
          </div>
        </div>
      </div>

      <hr className="margin-vert--xl" />

      <div className="container">
        <center>
          <h2 className="margin-bottom--lg">
            Integrate your identity provider for SSO to enforce 2FA / MFA.
          </h2>
        </center>
        <p>
          Only allow connections from authenticated users and automatically
          disable access for employees who have left. Firezone integrates with
          any OIDC and SAML 2.0 compatible identity provider for single sign-on
          (SSO).
        </p>
      </div>

      <div className="container">
        <div className="row">
          <div className="col col--2">
            <Link href="/docs/authenticate/oidc/keycloak/">
              <Image
                width={109}
                height={41}
                alt="keycloak logo"
                src="/images/keycloak-logo.png"
              />
            </Link>
          </div>
          <div className="col col--2">
            <Link href="/docs/authenticate/oidc/google/">
              <Image
                width={109}
                height={41}
                alt="google logo"
                src="/images/google-logo.png"
              />
            </Link>
          </div>
          <div className="col col--2">
            <Link href="/docs/authenticate/oidc/okta/">
              <Image
                width={109}
                height={41}
                alt="okta logo"
                src="/images/okta-logo.png"
              />
            </Link>
          </div>
          <div className="col col--2">
            <Link href="/docs/authenticate/oidc/onelogin/">
              <Image
                width={109}
                height={41}
                alt="onelogin logo"
                src="/images/onelogin-logo.png"
              />
            </Link>
          </div>
          <div className="col col--2">
            <Link href="/docs/authenticate/oidc/azuread/">
              <Image
                width={109}
                height={41}
                alt="azure logo"
                src="/images/azure-logo.png"
              />
            </Link>
          </div>
          <div className="col col--2">
            <Link href="/docs/authenticate/saml/jumpcloud/">
              <Image
                width={109}
                height={41}
                alt="jumpcloud logo"
                src="/images/jumpcloud-logo.png"
              />
            </Link>
          </div>
        </div>
      </div>

      <hr className="margin-vert--xl" />

      <div className="container">
        <center>
          <h2 className="margin-bottom--lg">Who can benefit from Firezone?</h2>
        </center>
        <p>
          Easy to deploy and manage for individuals and organizations alike.
        </p>
      </div>

      <div className="container margin-top--lg">
        <div className="row">
          <div className="col col--6">
            <div className="card">
              <div className="card__header">
                <h4>Individuals and home lab users</h4>
              </div>
              <div className="card__body">
                <p>
                  Lightweight and fast. Access your home network securely when
                  on the road.
                </p>
                <ul>
                  <li>Effortless to deploy on any infrastructure</li>
                  <li>Community plan supports unlimited devices</li>
                  <li>Open-source and self-hosted</li>
                </ul>
              </div>
              <div className="card__footer">
                <Link href="/docs">Access your personal project &gt;</Link>
              </div>
            </div>
          </div>
          <div className="col col--6">
            <div className="card">
              <div className="card__header">
                <h4>Growing businesses</h4>
              </div>
              <div className="card__body">
                <p>
                  Keep up with increasing network and compliance demands as you
                  scale your team and infrastructure.
                </p>
                <ul>
                  <li>Integrate your identity provider</li>
                  <li>Quickly onboard/offboard employees</li>
                  <li>Segment access for contractors</li>
                  <li>High performance, reduce bottlenecks</li>
                </ul>
              </div>
              <div className="card__footer">
                <Link href="/docs">Scale your secure access &gt;</Link>
              </div>
            </div>
          </div>
        </div>
        <div className="row margin-top--md">
          <div className="col col--6">
            <div className="card">
              <div className="card__header">
                <h4>Remote organizations</h4>
              </div>
              <div className="card__body">
                <p>
                  Transitioning to remote? Perfect timing to replace the legacy
                  VPN. Improve your security posture and reduce support tickets.
                </p>
                <ul>
                  <li>Require periodic re-authentication</li>
                  <li>Enforce MFA / 2FA</li>
                  <li>Self-serve user portal</li>
                  <li>Export logs to your observability platform</li>
                </ul>
              </div>
              <div className="card__footer">
                <Link href="/docs">Secure your remote workforce &gt;</Link>
              </div>
            </div>
          </div>
          <div className="col col--6">
            <div className="card">
              <div className="card__header">
                <h4>Technical IT teams</h4>
              </div>
              <div className="card__body">
                <p>
                  Firezone runs on your infrastructure. Customize it to suit
                  your needs and architecture.
                </p>
                <ul>
                  <li>Built on WireGuard®</li>
                  <li>No vendor lock-in</li>
                  <li>Supports OIDC and SAML 2.0</li>
                  <li>Flexible and configurable</li>
                </ul>
              </div>
              <div className="card__footer">
                <Link href="/docs">Explore the documentation &gt;</Link>
              </div>
            </div>
          </div>
        </div>
      </div>

      <hr className="margin-vert--xl" />

      <center>
        <h2 className="hero__title">Join our community</h2>
      </center>
      <p>Stay up to date with product launches and new features.</p>
      <div className="container margin-top--lg">
        <div className="row">
          <div className="col col--4">
            <div className="card">
              <div className="card__header">
                <center>
                  <h3 className="hero__title">30+</h3>
                </center>
              </div>
              <div className="card__body">
                <div>
                  <center>Contributors</center>
                </div>
              </div>
              <div className="card__footer">
                <center>
                  <a
                    className="button button--primary"
                    href="https://github.com/firezone/firezone/graphs/contributors"
                  >
                    Build Firezone
                  </a>
                </center>
              </div>
            </div>
          </div>
          <div className="col col--4">
            <div className="card">
              <div className="card__header">
                <center>
                  <h3 className="hero__title">4,100+</h3>
                </center>
              </div>
              <div className="card__body">
                <div>
                  <center>Github Stars</center>
                </div>
              </div>
              <div className="card__footer">
                <center>
                  <a
                    className="button button--primary"
                    href="https://github.com/firezone/firezone"
                  >
                    Github
                  </a>
                </center>
              </div>
            </div>
          </div>
          <div className="col col--4">
            <div className="card">
              <div className="card__header">
                <center>
                  <h3 className="hero__title">250+</h3>
                </center>
              </div>
              <div className="card__body">
                <div>
                  <center>Members</center>
                </div>
              </div>
              <div className="card__footer">
                <center>
                  <a
                    className="button button--primary"
                    href="https://firezone-users.slack.com/join/shared_invite/zt-19jd956j4-rWcCqiKMh~ikPGsUFbvZiA#/shared-invite/email"
                  >
                    Join Slack
                  </a>
                </center>
              </div>
            </div>
          </div>
        </div>
        <div className="row margin-top--md"></div>
      </div>

      <hr className="margin-vert--xl" />

      <center>
        <h2>Deploy self-hosted Firezone</h2>
      </center>

      <p>
        Set up secure access and start onboarding users in minutes. Run the
        install script on a supported host to deploy Firezone with Docker. Copy
        the one-liner below to install Firezone in minutes.
      </p>

      <InstallBlock />

      <div className="row margin-top--xl">
        <div className="col col--12">
          <center>
            <a className="button button--primary" href="/docs/deploy">
              Deploy now
            </a>
          </center>
        </div>
      </div>

      {/*
        <div className="col col&#45;&#45;6">
            <center>
                <a className="button button&#45;&#45;primary" href="/1.0/signup">
                Join the 1.0 beta wailist &#45;>
                </a>
            </center>
        </div>
        */}
    </div>
  );
}
