import Tooltip from "@/components/Tooltip";
import { FaCheck } from "react-icons/fa6";
import Link from "next/link";

export default function PlanTable() {
  return (
    <table className="w-full mx-auto text-left table-fixed max-w-screen-sm sm:max-w-screen-md">
      <thead>
        <tr>
          <th scope="col" className="w-1/3"></th>
          <th
            scope="col"
            className="text-lg mx-1 py-6 uppercase text-primary-450 text-center tracking-light"
          >
            Starter
          </th>
          <th
            scope="col"
            className="text-lg mx-1 py-6 uppercase text-primary-450 text-center tracking-light"
          >
            Team
          </th>
          <th
            scope="col"
            className="text-lg mx-1 py-6 uppercase text-primary-450 text-center tracking-light"
          >
            Enterprise
          </th>
        </tr>
      </thead>
      <tbody>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Includes both admins and end-users of your Firezone account">
              Users
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">6</td>
          <td className="font-semibold gmx-1 py-4 text-center">500</td>
          <td className="font-semibold gmx-1 py-4 text-center">Unlimited</td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Machine accounts used to access Resources without a user present">
              Service Accounts
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">10</td>
          <td className="font-semibold gmx-1 py-4 text-center">100</td>
          <td className="font-semibold gmx-1 py-4 text-center">Unlimited</td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Sites are a collection of Gateways and Resources that share the same network connectivity context. Typically a subnet or VPC.">
              Sites
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">10</td>
          <td className="font-semibold gmx-1 py-4 text-center">100</td>
          <td className="font-semibold gmx-1 py-4 text-center">Unlimited</td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Users with account-wide access to deploy Gateways, manage billing, and edit users, Sites, or other configuration">
              Admins
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">1</td>
          <td className="font-semibold gmx-1 py-4 text-center">10</td>
          <td className="font-semibold gmx-1 py-4 text-center">Unlimited</td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Policies control access to Resources (e.g. Group “A” may access Resource “B”)">
              Policies
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">Unlimited</td>
          <td className="font-semibold gmx-1 py-4 text-center">Unlimited</td>
          <td className="font-semibold gmx-1 py-4 text-center">Unlimited</td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Anything you wish to manage access to (e.g. database, VPC, home network, web server, SaaS application)">
              Resources
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">Unlimited</td>
          <td className="font-semibold gmx-1 py-4 text-center">Unlimited</td>
          <td className="font-semibold gmx-1 py-4 text-center">Unlimited</td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Any device or machine that the Firezone Client connects from">
              Connected Clients
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">3 per user</td>
          <td className="font-semibold gmx-1 py-4 text-center">5 per user</td>
          <td className="font-semibold gmx-1 py-4 text-center">Unlimited</td>
        </tr>
        <tr>
          <td
            colSpan={4}
            className="gmx-1 pt-12 pb-4 text-lg uppercase font-semibold text-primary-450 tracking-light"
          >
            Networking Features
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Connect to Resources without opening inbound firewall ports">
              NAT hole punching
            </Tooltip>
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Native client apps for all major platforms">
              Native Firezone Clients
            </Tooltip>
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Route traffic to Resources through Firezone leaving other traffic unaffected">
              Split tunneling
            </Tooltip>
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Connect to Resources over IPv4 or IPv6">
              IPv4 and IPv6 Resources
            </Tooltip>
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Connect to IPv6-only Resources from IPv4-only networks and vice-versa">
              Automatic NAT64
            </Tooltip>
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Route traffic through Firezone based on DNS matching rules">
              DNS-based routing
            </Tooltip>
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Spread traffic across multiple Gateways within a Site">
              Gateway load-balancing
            </Tooltip>
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Clients automatically switch from unhealthy Gateways to healthy ones">
              Automatic Gateway failover
            </Tooltip>
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Route all traffic from select Clients through Firezone">
              Full-tunnel routing
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr>
          <td
            colSpan={4}
            className="mx-1 pt-12 pb-4 text-lg uppercase font-semibold text-primary-450 tracking-light"
          >
            Authentication & Authorization
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Control access to Resources based on user identity and group">
              Resource-level access policies
            </Tooltip>
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4 justify-center">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Authenticate users with a one-time code sent to their email">
              Email (OTP) authentication
            </Tooltip>
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Authenticate users with any OIDC-compatible provider">
              OpenID Connect authentication
            </Tooltip>
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Allow access based on source IP, authentication method, time of day, or country.">
              Conditional access policies
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Customize the sign-in URL for your account. E.g. https://app.firezone.dev/your-organization">
              Custom account slug
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Automatically sync users and groups from Google Workspace to Firezone">
              Google Workspace directory sync
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Automatically sync users and groups from Microsoft Entra ID to Firezone">
              Microsoft Entra ID directory sync
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Automatically sync users and groups from Okta to Firezone">
              Okta directory sync
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr>
          <td
            colSpan={4}
            className="mx-1 pt-12 pb-4 text-lg uppercase font-semibold text-primary-450 tracking-light"
          >
            Security Features
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Rotate WireGuard encryption keys each time a user signs in">
              Session-based key rotation
            </Tooltip>
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Require Clients to be marked as verified in the admin portal before they can access Resources">
              Client verification
            </Tooltip>
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Show where your users are connecting from">
              GeoIP Mapping
            </Tooltip>
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="See who accessed which Resource and when">
              Resource access logs
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Restrict access to specific ports and protocols">
              Traffic restrictions
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Independent audit reports of Firezone's service for compliance with industry standards">
              Firezone service compliance reports
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">SOC 2</td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Penetration testing for security vulnerabilities in Firezone's service conducted by a third party firm">
              Firezone service pentest reports
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">40 hours</td>
        </tr>
        <tr>
          <td
            colSpan={4}
            className="mx-1 pt-12 pb-4 text-lg uppercase font-semibold text-primary-450 tracking-light"
          >
            Support & Customer success
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">Community Forums</td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">Community Discord</td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">Priority Email</td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">Dedicated Slack</td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Shape the product roadmap with customized features and integrations">
              Roadmap acceleration
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Get personalized deployment support and training for your team">
              White-glove onboarding
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="gmx-1 py-4">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Guaranteed uptime for your Firezone service">
              Uptime SLA
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">99.9%</td>
        </tr>
        <tr>
          <td
            colSpan={4}
            className="mx-1 pt-12 pb-4 text-lg uppercase font-semibold text-primary-450 tracking-light"
          >
            Billing & payment
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Pay for your subscription using a credit card">
              Payment by credit card
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Pay for your subscription using an ACH transfer">
              Payment by ACH transfer
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Pay for your subscription using a wire transfer">
              Payment by wire transfer
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-neutral-200">
          <td className="gmx-1 py-4">
            <Tooltip content="Pay for your subscription annually">
              Annual invoicing
            </Tooltip>
          </td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">&#8212;</td>
          <td className="font-semibold gmx-1 py-4 text-center">
            <FaCheck className="mx-auto shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr>
          <td></td>
          <td className="gmx-1 py-14 text-center">
            <Link href="https://app.firezone.dev/sign_up">
              <button
                type="button"
                className="md:text-lg md:py-2.5 text-sm sm:px-5 px-2.5 py-1.5 text-primary-450 font-semibold tracking-tight rounded-sm duration-50 hover:ring-2 transition transform shadow-lg border border-primary-450 hover:ring-primary-200"
              >
                Sign up
              </button>
            </Link>
          </td>
          <td className="gmx-1 py-14 text-center">
            <Link href="https://app.firezone.dev/sign_up">
              <button
                type="button"
                className="md:text-lg md:py-2.5 text-sm sm:px-5 px-2.5 py-1.5 text-primary-450 font-semibold tracking-tight rounded-sm duration-50 hover:ring-2 transition transform shadow-lg border border-primary-450 hover:ring-primary-200"
              >
                Sign up
              </button>
            </Link>
          </td>
          <td className="gmx-1 py-14 text-center">
            <Link href="/contact/sales">
              <button
                type="button"
                className="md:text-lg md:py-2.5 text-sm sm:px-5 px-2.5 py-1.5 text-white font-semibold tracking-tight rounded-sm duration-50 hover:ring-2 hover:ring-primary-300 transition transform shadow-lg bg-primary-450"
              >
                Contact us
              </button>
            </Link>
          </td>
        </tr>
      </tbody>
    </table>
  );
}
