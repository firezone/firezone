import Link from "next/link";
import Image from "next/image";
import ActionLink from "@/components/ActionLink";
import BattleCard from "@/components/BattleCard";
import { RunaCap } from "@/components/Badges";
import FeatureSection from "@/components/FeatureSection";
import { Metadata } from "next";
import { CustomerLogosGrayscale } from "@/components/CustomerLogos";
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
} from "@/components/Icons";

import {
  SlideIn,
  RotatingWords,
  Strike,
  FadeIn,
} from "@/components/Animations";
import ElevatorPitch from "@/components/ElevatorPitch";
import { manrope } from "@/lib/fonts";
import "@/styles/hero.css";
import CustomerTestimonials from "@/components/CustomerTestimonials";
import FeatureCards from "@/components/FeatureCards";
import SingleFeature from "@/components/SingleFeature";

export const metadata: Metadata = {
  title: "Firezone: Zero trust access that scales",
  description:
    "Firezone is a fast, flexible VPN replacement built on WireGuard® that eliminates tedious configuration and integrates with your identity provider.",
};

export default function Page() {
  return (
    <>
      <section className="bg-neutral-950 bg-hero pt-28 mb-16">
        <div className="flex flex-col items-center mx-auto md:px-0 px-4 max-w-screen-md">
          <h1
            className={
              manrope.className +
              " mb-8 text-5xl sm:text-6xl md:text-7xl text-center drop-shadow-[inset_0_2px_0_0_rgba(255,255,255,100)] font-medium tracking-tight leading-tight bg-gradient-to-b from-white from-70% to-slate-200 text-transparent bg-clip-text"
            }
          >
            Upgrade your VPN to zero-trust access
          </h1>
          <h3 className={"text-xl text-center text-neutral-400"}>
            Firezone is a fast, flexible VPN replacement built on WireGuard®
            that protects your most valuable resources without tedious
            configuration.
          </h3>
          <div className="flex sm:flex-row flex-col-reverse items-center justify-center sm:gap-x-6 md:gap-x-12 mt-10 w-full">
            <div className="flex items-center my-4 mr-4">
              <ActionLink
                size="lg"
                href="https://app.firezone.dev/sign_up"
                color="neutral-100"
                transitionColor="primary-450"
              >
                Get started for free
              </ActionLink>
            </div>
            <div className=" flex items-center w-full sm:w-fit">
              <button
                type="button"
                className="tracking-tight group shadow-primary-700 text-lg sm:w-48 w-full inline-flex shadow-lg justify-center items-center md:py-3 py-2 px-5 font-semibold text-center text-white rounded bg-primary-450 hover:ring-1 hover:ring-primary-450 duration-50 transform transition"
              >
                <Link href="/contact/sales">Book a demo</Link>
                <HiArrowLongRight className="group-hover:translate-x-1 transition duration-50 group-hover:scale-110 transform ml-2 -mr-1 w-7 h-7" />
              </button>
            </div>
          </div>
        </div>
        <div className="pt-16 pb-4 max-w-screen-xl mx-auto">
          <div className="text-center text-sm mb-6 font-base text-neutral-600">
            Backed by{" "}
            <Image
              src="/images/yc-logo-gray.svg"
              alt="yc logo gray"
              width={100}
              height={40}
              className="mx-1 md:mx-1.5 inline-flex pb-0.5"
            />{" "}
            and trusted by hundreds of organizations
          </div>
          <CustomerLogosGrayscale />
        </div>
      </section>

      <ElevatorPitch />

      <FeatureSection
        reverse
        titleCaption="Stay secure"
        title="Syncs with your identity provider"
        description={
          <p className="text-lg text-pretty text-neutral-800">
            Users and groups automatically sync with your identity provider,
            making onboarding and offboarding a breeze.
          </p>
        }
        image={
          <Image
            src="/images/feature-syncs-with-idp.png"
            width={463}
            height={437}
            alt="Syncs with your identity provider"
          />
        }
        cta={
          <ActionLink
            color="neutral-900"
            transitionColor="primary-450"
            size="lg"
            href="/kb/authenticate/directory-sync"
          >
            Set up directory sync
          </ActionLink>
        }
      />

      <FeatureSection
        titleCaption="Stay compliant"
        title={
          <span>
            <span className="text-primary-450">More control </span> over your
            network
          </span>
        }
        description={
          <p className="text-lg text-pretty text-neutral-800">
            Restrict access based on realtime conditions like device location,
            time of day, and more, and view every authorized connection by user,
            Resource, or policy.
          </p>
        }
        image={
          <Image
            src="/images/policy-conditions.png"
            width={598}
            height={553}
            alt="Policy conditions"
          />
        }
        cta={
          <ActionLink
            color="neutral-900"
            transitionColor="primary-450"
            size="lg"
            href="/kb/deploy/policies#conditional-access-policies"
          >
            See supported conditions
          </ActionLink>
        }
      />

      <section className="py-16">
        <div className="sm:mx-auto px-4 mb-8 text-3xl md:text-4xl lg:text-5xl text-pretty text-center">
          <h6 className="uppercase text-sm font-semibold text-primary-450 place-content-center tracking-wide">
            Flexible security
          </h6>
          <h3
            className={`tracking-tight font-bold leading-tight inline-block ${manrope.className}`}
          >
            Runs <span className="text-primary-450">everywhere </span>
            your business does
          </h3>
        </div>

        <div className="mx-auto px-4 mt-8 max-w-screen-lg grid sm:grid-cols-2 gap-8 lg:gap-16">
          <div className="flex flex-col p-4">
            <div className="mb-12 grid grid-cols-2 gap-6">
              <div className="py-5 flex items-center justify-center bg-neutral-200 rounded-lg">
                <AppleIcon size={12} href="/kb/client-apps/macos-client">
                  <span className="inline-block pt-4 w-full text-center">
                    macOS
                  </span>
                </AppleIcon>
              </div>
              <div className="py-5 flex items-center justify-center bg-neutral-200 rounded-lg">
                <WindowsIcon size={12} href="/kb/client-apps/windows-client">
                  <span className="inline-block pt-4 w-full text-center">
                    Windows
                  </span>
                </WindowsIcon>
              </div>
              <div className="py-5 flex items-center justify-center bg-neutral-200 rounded-lg">
                <LinuxIcon size={12} href="/kb/client-apps/linux-client">
                  <span className="inline-block pt-4 w-full text-center">
                    Linux
                  </span>
                </LinuxIcon>
              </div>
              <div className="py-5 flex items-center justify-center bg-neutral-200 rounded-lg">
                <AndroidIcon size={12} href="/kb/client-apps/android-client">
                  <span className="inline-block pt-4 w-full text-center">
                    Android
                  </span>
                </AndroidIcon>
              </div>
              <div className="py-5 flex items-center justify-center bg-neutral-200 rounded-lg">
                <ChromeIcon size={12} href="/kb/client-apps/android-client">
                  <span className="inline-block pt-4 w-full text-center">
                    ChromeOS
                  </span>
                </ChromeIcon>
              </div>
              <div className="py-5 flex items-center justify-center bg-neutral-200 rounded-lg">
                <AppleIcon size={12} href="/kb/client-apps/ios-client">
                  <span className="inline-block pt-4 w-full text-center">
                    iOS
                  </span>
                </AppleIcon>
              </div>
            </div>
            <div className="text-center md:text-left mt-auto">
              <p className="text-lg text-neutral-800">
                Clients are available for every major platform, require no
                configuration, and stay connected even when switching WiFi
                networks.
              </p>
              <p className="mt-4">
                <ActionLink
                  color="neutral-900"
                  transitionColor="primary-450"
                  size="lg"
                  href="/kb/client-apps"
                >
                  Download Client apps
                </ActionLink>
              </p>
            </div>
          </div>
          <div className="flex flex-col p-4">
            <div className="mb-12">
              <div className="py-0.5 flex flex-col justify-between space-y-8 md:space-y-12">
                <div className="mx-8 md:mx-16 flex justify-start">
                  <Image
                    width={200}
                    height={200}
                    alt="Gateway"
                    src="/images/docker.svg"
                  />
                </div>
                <div className="mx-8 md:mx-16 flex justify-end">
                  <Image
                    width={200}
                    height={200}
                    alt="Gateway"
                    src="/images/terraform.svg"
                  />
                </div>
                <div className="mx-8 md:mx-16 flex justify-start">
                  <Image
                    width={200}
                    height={200}
                    alt="Gateway"
                    src="/images/kubernetes.svg"
                  />
                </div>
                <div className="mx-8 md:mx-16 flex justify-end">
                  <Image
                    width={200}
                    height={200}
                    alt="Gateway"
                    src="/images/pulumi.svg"
                  />
                </div>
              </div>
              <pre className="mt-8 text-xs p-2 bg-neutral-950 rounded shadow text-neutral-50 text-wrap">
                <code>
                  <strong>FIREZONE_TOKEN</strong>=&lt;your-token&gt; \<br /> ./
                  <strong>firezone-gateway</strong>
                </code>
              </pre>
            </div>
            <div className="mt-auto text-center md:text-left">
              <p className="text-lg text-neutral-800">
                Gateways are lightweight Linux binaries you deploy anywhere you
                need access. Just configure a token with your preferred tool and
                you're done.
              </p>
              <p className="mt-4">
                <ActionLink
                  color="neutral-900"
                  transitionColor="primary-450"
                  size="lg"
                  href="/kb/deploy/gateways"
                >
                  Deploy your first Gateway
                </ActionLink>
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* Feature section: Open source for transparency and trust. */}
      <section className="py-16">
        <div className="sm:mx-auto px-4 mb-4 md:mb-8 text-3xl md:text-4xl lg:text-5xl text-pretty text-center">
          <h6 className="uppercase text-sm font-semibold place-content-center text-primary-450 tracking-wide">
            Open source
          </h6>
          <h3
            className={`tracking-tight font-bold inline-block ${manrope.className}`}
          >
            <span className="text-primary-450">Open source</span> for
            transparency and trust
          </h3>
        </div>

        <div className="mx-auto px-4 max-w-screen-md">
          <p className="text-lg text-center -mt-3 text-neutral-800 text-pretty">
            How can you trust a zero-trust solution if you can't see its source?
            We build Firezone in the open so anyone can make sure it does
            exactly what we claim it does, and nothing more.
          </p>
        </div>

        <div className="mx-auto flex max-w-screen-md justify-center mt-8">
          <Image
            src="https://api.star-history.com/svg?repos=firezone/firezone&type=Date"
            alt="Firezone stars"
            width={800}
            height={600}
            className="mx-auto px-4 md:px-0"
          />
        </div>
        <div className="flex flex-col justify-center items-center px-4">
          <div className="w-full flex flex-wrap max-w-screen-sm justify-between mt-8">
            <div className="mx-auto md:mx-0 min-w-48 w-auto mb-8 flex justify-center items-center">
              <RunaCap />
            </div>
            <div className="mx-auto md:mx-0 min-w-48 w-auto mb-8 flex justify-center items-center">
              <ActionLink
                color="neutral-900"
                transitionColor="primary-450"
                size="lg"
                href="https://www.github.com/firezone/firezone"
              >
                Leave us a star
              </ActionLink>
            </div>
          </div>
        </div>
      </section>

      <CustomerTestimonials />

      {/* Use cases */}
      <section className="py-16">
        <div className="mx-auto max-w-screen-lg">
          <div className={`px-4 flex flex-wrap ${manrope.className}`}>
            <h3 className="mb-2 text-2xl md:text-4xl tracking-tight font-bold mr-1">
              Yes, you can use Firezone to{" "}
            </h3>
            <h3 className="mb-2 text-2xl md:text-4xl tracking-tight font-bold">
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
            </h3>
          </div>
          <div className="px-4 flex flex-wrap mt-4">
            <h3 className="mb-2 text-xl md:text-2xl tracking-tight font-semibold">
              Here are just a few ways customers are using Firezone:
            </h3>
          </div>
          <div className="gap-4 items-center pt-8 px-4 mx-auto md:grid md:grid-cols-2 xl:gap-8 sm:pt-12 lg:px-6">
            <SlideIn delay={0.5} direction="right">
              <div className="bg-neutral-50 p-8 mt-4 md:mt-0 border border-neutral-200">
                <div className="flex items-center space-x-2.5">
                  <HiShieldCheck className=" lex-shrink-0 w-6 h-6 text-accent-600" />
                  <h4 className="text-xl tracking-tight font-bold text-neutral-900">
                    VPN Replacement
                  </h4>
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
            <SlideIn delay={0.5} direction="left">
              <div className="bg-neutral-50 p-8 mt-4 md:mt-0 border border-neutral-200">
                <div className="flex items-center space-x-2.5">
                  <HiRocketLaunch className="flex-shrink-0 w-6 h-6 text-accent-600" />
                  <h4 className="text-xl tracking-tight font-bold text-neutral-900 ">
                    Infrastructure Access
                  </h4>
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
            <SlideIn delay={0.5} direction="right">
              <div className="bg-neutral-50 p-8 mt-4 md:mt-0 border border-neutral-200">
                <div className="flex items-center space-x-2.5">
                  <HiGlobeAlt className=" lex-shrink-0 w-6 h-6 text-accent-600" />
                  <h4 className="text-xl tracking-tight font-bold text-neutral-900 ">
                    Internet Security
                  </h4>
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
            <SlideIn delay={0.5} direction="left">
              <div className="bg-neutral-50 p-8 mt-4 md:mt-0 border border-neutral-200">
                <div className="flex items-center space-x-2.5">
                  <HiHome className="flex-shrink-0 w-6 h-6 text-accent-600" />
                  <h4 className="text-xl tracking-tight font-bold text-neutral-900 ">
                    Homelab Access
                  </h4>
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
                      Authenticate with Email OTP or OIDC
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
          <div className="flex justify-center mt-8 md:mt-16">
            <ActionLink
              color="neutral-900"
              transitionColor="primary-450"
              size="lg"
              href="/kb/use-cases"
            >
              See more use cases
            </ActionLink>
          </div>
        </div>
      </section>

      <BattleCard />
    </>
  );
}
