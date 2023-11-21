import { Metadata } from "next";
import CustomerLogos from "@/components/CustomerLogos";
import RequestAccessButton from "@/components/RequestAccessButton";
import RequestDemoButton from "@/components/RequestDemoButton";
import { HiCheck } from "react-icons/hi2";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Pricing • Firezone",
  description: "Firezone pricing",
};

export default function Page() {
  return (
    <>
      <section className="bg-neutral-100">
        <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
          <div className="mx-auto max-w-screen-md sm:text-center">
            <h1 className="justify-center mb-4 text-2xl font-extrabold text-center leading-none tracking-tight text-neutral-900 sm:text-4xl">
              Plans & Pricing
            </h1>
          </div>
        </div>
      </section>
      <section className="bg-neutral-100 border-t border-neutral-200 pb-14">
        <div className="mx-auto max-w-screen-lg sm:grid sm:grid-cols-2 pt-14 sm:gap-4">
          <div className="p-8 bg-neutral-50 border-2 border-neutral-200">
            <h3 className="mb-4 text-2xl tracking-tight font-semibold text-primary-450">
              Starter
            </h3>
            <p className="mb-8">
              Secure remote access for individuals and small groups.
            </p>
            <h2 className="mb-16 text-2xl sm:text-4xl tracking-tight font-semibold text-neutral-900">
              Free
            </h2>
            <div className="mb-24 w-full text-center">
              <Link href="/product/early-access">
                <button
                  type="button"
                  className="w-64 text-white font-bold tracking-tight rounded duration-0 hover:scale-105 transition transform shadow-lg text-lg px-5 py-2.5 bg-gradient-to-br from-accent-700 to-accent-600"
                >
                  Request early access
                </button>
              </Link>
            </div>
            <ul role="list" className="font-medium space-y-2">
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-neutral-900 ">
                  Works on local area networks, NAS, Raspberry Pi, data centers,
                  and cloud VMs
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-neutral-900 ">
                  Remote access to your homelab
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-neutral-900 ">
                  Authenticate with magic link and OIDC
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-neutral-900 ">
                  Linux, macOS, iOS, ChromeOS, Android
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-neutral-900 ">
                  Community Support
                </span>
              </li>
            </ul>
          </div>
          <div className="p-8 bg-neutral-50 border-2 border-neutral-200">
            <h3 className="mb-4 text-2xl tracking-tight font-semibold text-primary-450">
              Enterprise
            </h3>
            <p className="mb-8">
              Zero trust network access for teams and organizations.
            </p>
            <h2 className="mb-16 text-2xl sm:text-4xl tracking-tight font-semibold text-neutral-900">
              Contact us
            </h2>
            <div className="mb-16 w-full text-center">
              <Link href="/contact/sales">
                <button
                  type="button"
                  className="w-64 text-white font-bold tracking-tight rounded duration-0 hover:scale-105 transition transform shadow-lg text-lg px-5 py-2.5 bg-gradient-to-br from-accent-700 to-accent-600"
                >
                  Request a demo
                </button>
              </Link>
            </div>
            <p className="mb-2">
              <strong>Everything in Starter, plus:</strong>
            </p>
            <ul role="list" className="font-medium space-y-2">
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-neutral-900 ">
                  SSO with Google Workspace
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-neutral-900 ">
                  Automatically sync users and groups
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-neutral-900 ">
                  Managed relay network
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-neutral-900 ">
                  Network access logs
                </span>
              </li>
              <li className="flex space-x-2.5">
                <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                <span className="leading-tight text-neutral-900 ">
                  Dedicated Slack and email support
                </span>
              </li>
            </ul>
          </div>
        </div>
      </section>
      <section className="bg-neutral-50 border-t border-neutral-200">
        <div className="mx-auto max-w-screen-xl">
          <CustomerLogos />
        </div>
      </section>
      <section className="bg-white border-t border-neutral-200 py-14">
        <div className="mb-14 mx-auto max-w-screen-md">
          <h2 className="mb-14 justify-center text-4xl font-semibold text-neutral-900">
            Compare plans
          </h2>
          <table className="w-full mx-auto text-left">
            <thead>
              <tr>
                <th></th>
                <th
                  scope="col"
                  className="px-6 py-6 uppercase text-primary-450 tracking-light"
                >
                  Starter
                </th>
                <th
                  scope="col"
                  className="px-6 py-6 uppercase text-primary-450 tracking-light"
                >
                  Enterprise
                </th>
              </tr>
            </thead>
            <tbody>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Users</td>
                <td className="px-6 py-4">10</td>
                <td className="px-6 py-4">No limit</td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Service Accounts</td>
                <td className="px-6 py-4">10</td>
                <td className="px-6 py-4">No limit</td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Admins</td>
                <td className="px-6 py-4">1</td>
                <td className="px-6 py-4">No limit</td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Sites</td>
                <td className="px-6 py-4">3</td>
                <td className="px-6 py-4">No limit</td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Policies</td>
                <td className="px-6 py-4">No limit</td>
                <td className="px-6 py-4">No limit</td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Resources</td>
                <td className="px-6 py-4">No limit</td>
                <td className="px-6 py-4">No limit</td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Devices</td>
                <td className="px-6 py-4">No limit</td>
                <td className="px-6 py-4">No limit</td>
              </tr>
              <tr>
                <td className="px-6 pt-8 pb-4 text-lg font-semibold text-primary-450 tracking-light">
                  Networking Features
                </td>
                <td></td>
                <td></td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">NAT hole punching</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Cloud & local networks</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Native Firezone clients</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Split tunneling</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">DNS-based routing</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Gateway load-balancing</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Automatic gateway failover</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Global relay network</td>
                <td className="px-6 py-4">&#8212;</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr>
                <td className="px-6 pt-8 pb-4 text-lg font-semibold text-primary-450 tracking-light">
                  Authentication & Authorization
                </td>
                <td></td>
                <td></td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Resource-level access policies</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Universal OIDC connector</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Google Workspace integration</td>
                <td className="px-6 py-4">&#8212;</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">User / group sync</td>
                <td className="px-6 py-4">&#8212;</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr>
                <td className="px-6 pt-8 pb-4 text-lg font-semibold text-primary-450 tracking-light">
                  Security Features
                </td>
                <td></td>
                <td></td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Daily key rotation</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Policy authorization logs</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Geomapped IPs</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr>
                <td className="px-6 pt-8 pb-4 text-lg font-semibold text-primary-450 tracking-light">
                  Support
                </td>
                <td></td>
                <td></td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Community Forums</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Community Slack</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Priority Email</td>
                <td className="px-6 py-4">&#8212;</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
              <tr className="border-b border-1 border-neutral-200">
                <td className="px-6 py-4">Dedicated Slack</td>
                <td className="px-6 py-4">&#8212;</td>
                <td className="px-6 py-4">
                  <HiCheck className="flex-shrink-0 w-5 h-5 text-neutral-900" />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
      <section className="bg-neutral-100 border-t border-neutral-200 py-14">
        <div className="mx-auto max-w-screen-md">
          <h2 className="mb-14 justify-center text-4xl font-semibold text-neutral-900">
            Frequently Asked Questions
          </h2>

          <blockquote className="text-lg italic p-4 my-4 border-s-4 border-neutral-300">
            <p>How long does it take to set up Firezone?</p>
          </blockquote>
          <p>
            Firezone can be set up in less than 10 minutes, and gateways can be
            added by running a simple Docker command. Visit our docs for more
            information and step by step instructions.
          </p>

          <blockquote>
            <p>
              How will my employees and contractors be affected if I set up
              Firezone?
            </p>
          </blockquote>
          <p>
            Firezone can be installed alongside your current access solutions,
            so users won’t experience any interruptions. Employees can switch to
            Firezone by downloading and activating the client. Since no other
            changes are necessary, employees can keep accessing the resources
            they need (without any assistance from IT).
          </p>

          <blockquote>
            <p>Do I need to remove my current VPN to use Firezone?</p>
          </blockquote>
          <p>
            No, you can run Firezone alongside your existing VPN, and switch
            over whenever you’re ready. There’s no need for any downtime or
            unnecessary disruptions.
          </p>

          <blockquote>
            <p>What happens to my data with Firezone enabled?</p>
          </blockquote>
          <p>
            Network traffic is always end-to-end encrypted, and by default,
            routes directly to gateways running on your infrastructure. If you
            have managed relays enabled, encrypted data may pass through our
            global relay network if a direct connection cannot be established.
            Firezone can never decrypt the contents of your traffic.
          </p>

          <blockquote>
            <p>How do I cancel or change my plan?</p>
          </blockquote>
          <p>
            Please contact support (support@firezone.dev) if you would like to
            change your plan or terminate your account.
          </p>

          <blockquote>
            <p>When will I be billed?</p>
          </blockquote>
          <p>
            When you start service, or at the beginning of each billing
            cycle.Enterprise plans are billed quarterly or annually.
          </p>

          <blockquote>
            <p>What payment methods are available?</p>
          </blockquote>
          <p>
            The Starter plan is free and does not require a credit card to be
            entered. Enterprise plans can be paid via credit card, ACH, or wire
            transfer and will have a 100% discount applied for the duration of
            the beta.
          </p>

          <blockquote>
            <p>
              Other than using Firezone, is there anything I can do to improve
              my cybersecurity?
            </p>
          </blockquote>
          <p>
            Firezone helps protect your network and private resources, however,
            organizations should consider a balanced security and risk
            management posture that takes into account all the different parts
            of their business.
          </p>

          <blockquote>
            <p>
              Do you offer special pricing for nonprofits and educational
              institutions?
            </p>
          </blockquote>
          <p>
            Yes. Not-for-profit organizations and educational institutions are
            eligible for a 50% discount. Contact us (support@firezone.dev) to
            apply for the discount.
          </p>
        </div>
      </section>
    </>
  );
}
