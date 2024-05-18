import CodeBlock from "@/components/CodeBlock";
import Link from "next/link";
import Image from "next/image";
import ActionLink from "@/components/ActionLink";
import BattleCard from "@/components/BattleCard";
import { Metadata } from "next";
import CustomerLogos from "@/components/CustomerLogos";
import {
  HiShieldCheck,
  HiCheck,
  HiFingerPrint,
  HiArrowLongRight,
  HiGlobeAlt,
  HiHome,
  HiRocketLaunch,
} from "react-icons/hi2";
import {
  AppleIcon,
  WindowsIcon,
  LinuxIcon,
  AndroidIcon,
  ChromeIcon,
  DockerIcon,
} from "@/components/Icons";

import { SlideIn, RotatingWords, Strike } from "@/components/Animations";

export const metadata: Metadata = {
  title: "Firezone: Zero trust access that scales",
  description:
    "Firezone is a fast, flexible VPN replacement built on WireGuard® that eliminates tedious configuration and integrates with your identity provider.",
};

function ActionButtons() {
  return (
    <div className="w-full max-w-screen-sm flex space-x-2 justify-between mt-8">
      <button
        type="button"
        className="w-64 inline-flex justify-center items-center py-3 px-5 text-base font-semibold hover:font-bold text-center text-primary-450 rounded border border-primary-450 bg-white hover:scale-105 duration-0 transform transition"
      >
        <Link href="https://app.firezone.dev/sign_up">Sign up now</Link>
      </button>
      <button
        type="button"
        className="w-64 inline-flex shadow-lg justify-center items-center py-3 px-5 text-base font-semibold hover:font-bold text-center text-white rounded bg-primary-450 hover:scale-105 duration-0 transform transition"
      >
        <Link href="/contact/sales">Request demo</Link>
        <HiArrowLongRight className="ml-2 -mr-1 w-6 h-6" />
      </button>
    </div>
  );
}

export default function Page() {
  return (
    <>
      <section className="bg-neutral-100 pt-24">
        <div className="px-4 py-8 mx-auto max-w-screen-xl text-center lg:py-16 lg:px-12">
          <h1 className="mb-8 md:text-6xl text-5xl justify-center inline-block font-extrabold tracking-tight leading-none text-neutral-900">
            Secure remote access.
            <SlideIn
              direction="left"
              delay={0.5}
              className="ml-2 text-primary-450 underline md:inline-block"
            >
              That scales.
            </SlideIn>
          </h1>
          <h2 className="mb-8 text-xl tracking-tight justify-center font-medium text-neutral-900 sm:px-16 xl:px-48 inline-block">
            Firezone is a fast, flexible VPN replacement built on WireGuard®
            that <span className="text-primary-450 font-bold">eliminates</span>{" "}
            tedious configuration and integrates with your identity provider.
          </h2>
          <div className="mb-12 flex flex-col px-4 justify-center items-center">
            <ActionButtons />
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
        </div>
      </section>

      {/* Customer logos */}
      <section className="py-24 bg-gradient-to-b to-white from-neutral-100 via-primary-100">
        <CustomerLogos />
      </section>

      <section className="border-t border-neutral-200 py-24 bg-neutral-100">
        <div className="mx-auto max-w-screen-lg">
          <div className="px-4 flex flex-wrap">
            <h2 className="mb-2 text-2xl md:text-4xl tracking-tight font-bold mr-1">
              Yes, you can use Firezone to{" "}
            </h2>
            <h2 className="mb-2 text-2xl md:text-4xl tracking-tight font-bold">
              <RotatingWords
                className="underline text-primary-450 mx-0.5 sm:mx-1 inline-flex"
                words={[
                  "secure DNS for your workforce",
                  "securely access GitLab",
                  "scale access to your VPC",
                  "access your homelab",
                  "route through a public IP",
                  "access your Postgres DB",
                  "tunnel IPv6 over IPv4",
                  "restrict access to GitHub",
                  "tunnel to a remote host",
                ]}
              />
            </h2>
          </div>
        </div>
        <div className="gap-4 items-center pt-8 px-4 mx-auto max-w-screen-xl md:grid md:grid-cols-2 xl:gap-8 sm:pt-16 lg:px-6">
          <SlideIn direction="right">
            <div className="bg-neutral-50 p-8 border border-neutral-200">
              <div className="flex items-center space-x-2.5">
                <HiShieldCheck className=" lex-shrink-0 w-6 h-6 text-accent-600" />
                <h3 className="text-xl tracking-tight font-bold text-neutral-900">
                  VPN Replacement
                </h3>
              </div>
              <p className="mt-8 text-neutral-900 text-xl">
                Remote employees can securely access office networks, cloud
                VPCs, and other private subnets and resources from anywhere in
                the world, on any device.
              </p>
              <ul role="list" className="my-6 lg:mb-0 space-y-4">
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Easy to use, no training required
                  </span>
                </li>
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Authenticate with virtually any IdP
                  </span>
                </li>
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Highly available Gateways
                  </span>
                </li>
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Modern encryption and authentication
                  </span>
                </li>
              </ul>
            </div>
          </SlideIn>
          <SlideIn direction="left">
            <div className="bg-neutral-50 p-8 border border-neutral-200">
              <div className="flex items-center space-x-2.5">
                <HiRocketLaunch className="flex-shrink-0 w-6 h-6 text-accent-600" />
                <h3 className="text-xl tracking-tight font-bold text-neutral-900 ">
                  Infrastructure Access
                </h3>
              </div>
              <p className="mt-8 text-neutral-900 text-xl">
                Empower engineers and DevOps to manage their team’s access to
                technical resources like test/prod servers both on-prem and in
                the cloud.
              </p>
              <ul role="list" className="my-6 lg:mb-0 space-y-4">
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Service accounts and headless clients
                  </span>
                </li>
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Multiple admins per account
                  </span>
                </li>
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Docker and Terraform integrations
                  </span>
                </li>
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Automatically sync users and groups from your IdP
                  </span>
                </li>
              </ul>
            </div>
          </SlideIn>
          <SlideIn direction="right">
            <div className="bg-neutral-50 p-8 border border-neutral-200">
              <div className="flex items-center space-x-2.5">
                <HiGlobeAlt className=" lex-shrink-0 w-6 h-6 text-accent-600" />
                <h3 className="text-xl tracking-tight font-bold text-neutral-900 ">
                  Internet Security
                </h3>
              </div>
              <p className="mt-8 text-neutral-900 text-xl">
                Route sensitive internet traffic through a trusted gateway to
                keep remote employees more secure, even when they’re traveling
                or using public WiFi.
              </p>
              <ul role="list" className="my-6 lg:mb-0 space-y-4">
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Native clients for all major platforms
                  </span>
                </li>
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Enforce MFA / 2FA
                  </span>
                </li>
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Filter malicious or unwanted DNS requests
                  </span>
                </li>
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Monitor and audit each attempted connection
                  </span>
                </li>
              </ul>
            </div>
          </SlideIn>
          <SlideIn direction="left">
            <div className="bg-neutral-50 p-8 border border-neutral-200">
              <div className="flex items-center space-x-2.5">
                <HiHome className="flex-shrink-0 w-6 h-6 text-accent-600" />
                <h3 className="text-xl tracking-tight font-bold text-neutral-900 ">
                  Homelab Access
                </h3>
              </div>
              <p className="mt-8 text-neutral-900 text-xl">
                Securely access your home network, and services like Plex,
                security cameras, a Raspberry Pi, and other self-hosted apps
                when you’re away from home.
              </p>
              <ul role="list" className="my-6 lg:mb-0 space-y-4">
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Easy to setup and simple to manage
                  </span>
                </li>
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Authenticate with Magic link or OIDC
                  </span>
                </li>
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Reliable NAT traversal
                  </span>
                </li>
                <li className="flex space-x-2.5">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                  <span className="leading-tight text-lg text-neutral-900 ">
                    Invite friends and family to your private network
                  </span>
                </li>
              </ul>
            </div>
          </SlideIn>
        </div>
      </section>

      {/* Feature section 1: Secure access to your most sensitive resources in minutes. */}
      <section className="bg-white py-8 md:py-16">
        <div className="sm:mx-auto px-4 mb-2 md:mb-4">
          <h2 className="text-xl sm:text-2xl md:text-4xl sm:justify-center tracking-tight font-bold">
            Upgrade to zero-trust access in{" "}
            <span className="ml-0.5 sm:ml-1 -mr-0.5 text-primary-450">
              minutes
            </span>
            .
          </h2>
        </div>

        <div className="mx-auto px-4 max-w-screen-md">
          <p className="text-md md:text-xl sm:text-center tracking-tight">
            Replace your obsolete VPN with a modern zero trust upgrade. Firezone
            supports the workflows and access patterns you're already familiar
            with, so you can get started in minutes and incrementally adopt zero
            trust over time.
          </p>
        </div>

        <div className="flex items-stretch mx-auto px-4 md:px-8 mt-8 md:mt-16 gap-8 max-w-sm md:max-w-screen-lg grid md:grid-cols-3">
          <SlideIn
            direction="left"
            delay={0.25}
            className="flex items-end p-4 border border-primary-450 rounded shadow justify-center"
          >
            <p className="text-sm md:text-lg lg:text-xl tracking-tight">
              Control access to VPCs, subnets, hosts, and even DNS-based
              services.
            </p>
          </SlideIn>
          <SlideIn
            direction="left"
            delay={0.5}
            className="flex items-end p-4 border border-primary-450 rounded shadow justify-center"
          >
            <p className="text-sm md:text-lg lg:text-xl tracking-tight">
              Group-based policies automatically sync with your IdP, so access
              is revoked immediately when employees leave.
            </p>
          </SlideIn>
          <SlideIn
            direction="left"
            delay={0.75}
            className="flex items-end p-4 border border-primary-450 rounded shadow justify-center"
          >
            <p className="text-sm md:text-lg lg:text-xl tracking-tight">
              Restrict access even further with port-level rules that allow
              access to some services but not others, even on the same host.
            </p>
          </SlideIn>
        </div>

        <div className="flex justify-center mt-8 md:mt-16">
          <ActionLink
            className="underline hover:no-underline text-md md:text-xl tracking-tight font-medium text-accent-500"
            href="/kb/deploy/resources"
          >
            Protect your resources
          </ActionLink>
        </div>
      </section>

      {/* Feature section 2: Add 2FA to WireGuard. */}
      <section className="bg-neutral-50 py-8 md:py-16">
        <div className="sm:mx-auto px-4 mb-2 md:mb-4">
          <h2 className="text-xl sm:text-2xl md:text-4xl sm:justify-center tracking-tight font-bold">
            Add{" "}
            <span className="mx-0.5 sm:mx-1 text-primary-450">two-factor</span>
            auth to WireGuard.
          </h2>
        </div>

        <div className="mx-auto px-4 max-w-screen-md">
          <p className="text-md md:text-xl sm:text-center tracking-tight">
            Looking for 2FA for WireGuard? Look no further. Firezone integrates
            with any OIDC-compatible identity provider to consistently enforce
            multi-factor authentication across your workforce.
          </p>
        </div>

        <div className="flex justify-center mt-8 md:mt-16">
          <ActionLink
            className="underline hover:no-underline text-md md:text-xl tracking-tight font-medium text-accent-500"
            href="/kb/authenticate"
          >
            Connect your identity provider
          </ActionLink>
        </div>
      </section>

      {/* Feature section 3: No more open firewall ports. */}
      <section className="bg-white py-8 md:py-16">
        <div className="sm:mx-auto px-4 mb-2 md:mb-4">
          <h2 className="text-xl sm:text-2xl md:text-4xl sm:justify-center tracking-tight font-bold">
            Say <span className="mx-0.5 sm:mx-1 text-primary-450">goodbye</span>{" "}
            to firewall configuration.
          </h2>
        </div>

        <div className="mx-auto px-4 max-w-screen-md">
          <p className="text-md md:text-xl sm:text-center tracking-tight">
            Firezone securely punches through firewalls with ease, so keep those
            ports closed. Connections always pick the shortest path and your
            attack surface is minimized, keeping your most sensitive resources
            safe.
          </p>
        </div>

        <div className="flex justify-center mt-8 md:mt-16">
          <ActionLink
            className="underline hover:no-underline text-md md:text-xl tracking-tight font-medium text-accent-500"
            href="/kb/deploy"
          >
            Make your resources invisible
          </ActionLink>
        </div>
      </section>

      {/* Feature section 4: Say goodbye to bandwidth problems. */}
      <section className="bg-neutral-900 text-neutral-50 py-8 md:py-16">
        <div className="sm:mx-auto px-4 mb-2 md:mb-4">
          <h2 className="text-xl sm:text-2xl md:text-4xl sm:justify-center tracking-tight font-bold">
            <Strike>Bandwidth problems.</Strike>
          </h2>
        </div>

        <div className="mx-auto px-4 max-w-screen-md">
          <p className="text-md md:text-xl sm:text-center tracking-tight">
            Eliminate throughput bottlenecks that plague other VPNs. Firezone's
            load-balancing architecture scales horizontally to handle an
            unlimited number of connections to even the most bandwidth-intensive
            services. Need more speed? Just add more Gateways.
          </p>
        </div>

        <div className="flex justify-center mt-8 md:mt-16">
          <ActionLink
            className="underline hover:no-underline text-md md:text-xl tracking-tight font-semibold text-primary-450"
            href="/kb/use-cases/scale-vpc-access"
          >
            Scale access to your VPCs
          </ActionLink>
        </div>
      </section>

      {/* Feature section 5: Achieve compliance in minutes, not weeks. */}
      <section className="bg-white py-8 md:py-16">
        <div className="sm:mx-auto px-4 mb-2 md:mb-4">
          <h2 className="text-xl sm:text-2xl md:text-4xl sm:justify-center tracking-tight font-bold">
            Achieve compliance in{" "}
            <span className="ml-0.5 sm:ml-1 -mr-0.5 text-primary-450">
              minutes
            </span>
            , not weeks.
          </h2>
        </div>

        <div className="mx-auto px-4 max-w-screen-md">
          <p className="text-md md:text-xl sm:text-center tracking-tight">
            Connections are always end-to-end encrypted with keys that rotate
            daily, and are directly established between your Users and Gateways,
            so we can never see your data. And detailed activity logs show who
            accessed what and when, so you can easily demonstrate compliance
            with internal and external security audits.
          </p>
        </div>

        <div className="flex justify-center mt-8 md:mt-16">
          <ActionLink
            className="underline hover:no-underline text-md md:text-xl tracking-tight font-medium text-accent-500"
            href="/kb/architecture"
          >
            Read about Firezone's architecture
          </ActionLink>
        </div>
      </section>

      {/* Feature section 6: Runs everywhere your business does. */}
      <section className="bg-neutral-50 py-8 md:py-16">
        <div className="sm:mx-auto px-4 mb-2 md:mb-4">
          <h2 className="text-xl sm:text-2xl md:text-4xl sm:justify-center tracking-tight font-bold">
            Runs{" "}
            <span className="mx-0.5 sm:mx-1 text-primary-450">everywhere</span>{" "}
            your business does.
          </h2>
        </div>

        <div className="mx-auto px-4 mt-8 md:mt-16 max-w-screen-lg grid sm:grid-cols-2 gap-8 lg:gap-16">
          <div className="p-4">
            <div className="grid grid-cols-2 gap-4">
              <div className="p-4 flex items-center justify-center bg-white rounded-lg border border-2 border-neutral-200">
                <AppleIcon size={12} href="/kb/user-guides/macos-client">
                  <span className="inline-block pt-4 w-full text-center">
                    macOS
                  </span>
                </AppleIcon>
              </div>
              <div className="p-4 flex items-center justify-center bg-white rounded-lg border border-2 border-neutral-200">
                <WindowsIcon size={12} href="/kb/user-guides/windows-client">
                  <span className="inline-block pt-4 w-full text-center">
                    Windows
                  </span>
                </WindowsIcon>
              </div>
              <div className="p-4 flex items-center justify-center bg-white rounded-lg border border-2 border-neutral-200">
                <LinuxIcon size={12} href="/kb/user-guides/linux-client">
                  <span className="inline-block pt-4 w-full text-center">
                    Linux
                  </span>
                </LinuxIcon>
              </div>
              <div className="p-4 flex items-center justify-center bg-white rounded-lg border border-2 border-neutral-200">
                <AndroidIcon size={12} href="/kb/user-guides/android-client">
                  <span className="inline-block pt-4 w-full text-center">
                    Android
                  </span>
                </AndroidIcon>
              </div>
              <div className="p-4 flex items-center justify-center bg-white rounded-lg border border-2 border-neutral-200">
                <ChromeIcon size={12} href="/kb/user-guides/android-client">
                  <span className="inline-block pt-4 w-full text-center">
                    ChromeOS
                  </span>
                </ChromeIcon>
              </div>
              <div className="p-4 flex items-center justify-center bg-white rounded-lg border border-2 border-neutral-200">
                <AppleIcon size={12} href="/kb/user-guides/macos-client">
                  <span className="inline-block pt-4 w-full text-center">
                    iOS
                  </span>
                </AppleIcon>
              </div>
            </div>
            <p className="mt-4 md:mt-8 text-md md:text-xl tracking-tight md:text-justify">
              Clients are available for every major platform, require no
              configuration, and stay connected seamlessly even when switching
              WiFi networks.
            </p>
            <p className="mt-4">
              <ActionLink
                className="underline hover:no-underline text-md md:text-xl tracking-tight font-medium text-accent-500"
                href="/kb/user-guides"
              >
                Download Client apps
              </ActionLink>
            </p>
          </div>
          <div className="p-4">
            <div className="flex flex-col justify-between space-y-4 items-center">
              <Image
                width={300}
                height={200}
                alt="Gateway"
                src="/images/docker.svg"
              />
              <Image
                width={300}
                height={200}
                alt="Gateway"
                src="/images/terraform.svg"
              />
              <Image
                width={300}
                height={200}
                alt="Gateway"
                src="/images/kubernetes.svg"
              />
              <Image
                width={300}
                height={200}
                alt="Gateway"
                src="/images/pulumi.svg"
              />
            </div>
            <pre className="mt-4 md:mt-8 text-xs p-2 bg-neutral-900 rounded shadow text-neutral-50 text-wrap">
              <code>
                <strong>FIREZONE_TOKEN</strong>=&lt;your-token&gt; \<br /> ./
                <strong>firezone-gateway</strong>
              </code>
            </pre>
            <p className="mt-4 md:mt-8 text-md md:text-xl tracking-tight md:text-justify">
              Gateways are lightweight Linux binaries you deploy anywhere you
              need access. Just configure a token with your preferred
              orchestration tool and you're done.
            </p>
            <p className="mt-4">
              <ActionLink
                className="underline hover:no-underline text-md md:text-xl tracking-tight font-medium text-accent-500"
                href="/kb/user-guides"
              >
                Deploy your first Gateway
              </ActionLink>
            </p>
          </div>
        </div>

        <div className="flex justify-center mt-8 md:mt-16"></div>
      </section>

      {/* Feature section 7: Open source for transparency and trust. */}
      <section className="bg-white py-8 md:py-16">
        <div className="sm:mx-auto px-4 mb-2 md:mb-4">
          <h2 className="text-xl sm:text-2xl md:text-4xl sm:justify-center tracking-tight font-bold">
            <span className="mx-0.5 sm:mx-1 text-primary-450">Open source</span>{" "}
            for transparency and trust.
          </h2>
        </div>

        <div className="mx-auto px-4 max-w-screen-md">
          <p className="text-md md:text-xl sm:text-center tracking-tight">
            How can you trust a zero-trust solution if you can't see its source?
            We build Firezone in the open so anyone can make sure it does
            exactly what we claim it does, and nothing more.
          </p>

          <div className="flex justify-center mt-8 md:mt-16">
            <ActionLink
              className="underline hover:no-underline text-md md:text-xl tracking-tight font-medium text-accent-500"
              href="https://www.github.com/firezone/firezone"
            >
              Leave us a star
            </ActionLink>
          </div>
        </div>
      </section>

      {/* Features sections */}
      <section className="bg-white py-24">
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
            <p className="text-xl text-neutral-900 my-4">
              Replace your obsolete VPN with a modern zero trust upgrade.
              Firezone supports the workflows and access patterns you're already
              familiar with, so you can get started in minutes and incrementally
              adopt zero trust over time.
            </p>
            <ul role="list" className="font-medium my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="text-lg text-neutral-900 ">
                  Create a{" "}
                  <Link
                    className="text-accent-500 underline hover:no-underline"
                    href="/kb/deploy/sites?utm_source=website"
                  >
                    Site
                  </Link>
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Deploy one or more{" "}
                  <Link
                    className="text-accent-500 underline hover:no-underline"
                    href="/kb/deploy/gateways?utm_source=website"
                  >
                    Gateways
                  </Link>
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Add a{" "}
                  <Link
                    className="text-accent-500 underline hover:no-underline"
                    href="/kb/deploy/resources?utm_source=website"
                  >
                    Resource
                  </Link>{" "}
                  (e.g. subnet, host or service)
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
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
            <p className="text-xl text-neutral-900 my-4">
              Firezone is fast and dependable so your team is always connected
              to the resources they need most. It works on all major platforms
              and stays connected even when switching WiFi networks.
            </p>
            <ul role="list" className="font-medium my-6 lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Automatic NAT traversal
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Global relay network
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Automatic Gateway failover and load balancing
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
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
            <p className="text-xl text-neutral-900 my-4">
              Firezone establishes secure, direct tunnels between your users and
              Gateways, then gets out of the way. Gateways are deployed on your
              infrastructure, so you retain full control over your data at all
              times.
            </p>
            <ul role="list" className="my-6 font-medium lg:mb-0 space-y-4">
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Deploy Gateways as Docker containers or standalone binaries
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Connect VPC, data center, on-prem, and cloud resources
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-lg text-neutral-900 ">
                  Permit access with group-based policies to specific hosts,
                  applications, or subnets
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
          <h2 className="mb-8 underline text-5xl justify-center text-center tracking-tight font-bold text-neutral-900 ">
            Next-Gen security...
          </h2>
          <h3 className="my-4 text-xl font-medium tracking-tight max-w-screen-lg text-center text-neutral-900 ">
            Built from the ground up with modern security best practices in
            mind:
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
                firewall configuration needed.
              </p>
            </li>
            <li className="flex space-x-5">
              <HiShieldCheck className="text-accent-600 flex-shrink-0 w-7 h-7" />
              <p>
                <strong>Self-hosted Gateways</strong> and end-to-end encryption
                ensure we{" "}
                <strong className="text-primary-450">can never</strong> see your
                data.
              </p>
            </li>
          </ul>
        </div>
        <div className="mx-4 mb-8 flex flex-col justify-center items-center">
          <h2 className="inline-block mb-8 underline text-5xl justify-center text-center tracking-tight font-bold text-neutral-900 ">
            ...that works <span className="text-primary-450">with</span> your
            IdP
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
              <p className="mt-4 font-medium text-neutral-900 text-lg">
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
              <p className="mt-4 font-medium text-neutral-900 text-lg">
                Sync IdP users and groups to ensure active employees can access
                your network, and revoke access when employees leave.
              </p>
              <p className="mt-2 text-neutral-900 text-xs">
                * Currently available for Google Workspace, Microsoft Entra ID,
                and Okta.
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
        <BattleCard />
      </section>

      <section className="border-t border-neutral-200 py-24 bg-neutral-900">
        <div className="flex flex-col px-4 justify-center items-center">
          <h2 className="mb-4 text-4xl tracking-tight text-center font-bold text-neutral-50">
            Ready to get started?
          </h2>
          <h3 className="my-4 font-medium text-xl max-w-screen-md tracking-tight text-center text-neutral-200 ">
            Give your team secure access to company resources in minutes.
          </h3>
          <ActionButtons />
        </div>
      </section>
    </>
  );
}
