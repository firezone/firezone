"use client";

import { Tooltip } from "flowbite-react";
import { HiCheck } from "react-icons/hi2";
import { useEffect } from "react";
import { initFlowbite } from "flowbite";
import Link from "next/link";

export default function PlanTable() {
  useEffect(() => {
    // Manually init flowbite's data-toggle listeners since we're using custom components
    initFlowbite();
  }, []);
  return (
    <table className="w-full mx-auto text-left">
      <thead>
        <tr>
          <th></th>
          <th
            scope="col"
            className="px-6 py-6 uppercase text-primary-450 text-center tracking-light"
          >
            Starter
          </th>
          <th
            scope="col"
            className="px-6 py-6 uppercase text-primary-450 text-center tracking-light"
          >
            Enterprise
          </th>
        </tr>
      </thead>
      <tbody>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">
            <span
              data-tooltip-target="users-tooltip"
              data-tooltip-placement="top"
              className="underline hover:no-underline cursor-help"
            >
              Users
            </span>
            <div
              id="users-tooltip"
              role="tooltip"
              className="absolute z-10 invisible inline-block px-3 py-2 text-xs font-medium text-white transition-opacity duration-100 bg-neutral-900 rounded shadow-sm opacity-90 tooltip"
            >
              Human operators and end-users of your Firezone account
              <div className="tooltip-arrow" data-popper-arrow></div>
            </div>
          </td>
          <td className="px-6 py-4 text-center">10</td>
          <td className="px-6 py-4 text-center">No limit</td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">
            <span
              data-tooltip-target="sa-tooltip"
              data-tooltip-placement="top"
              className="underline hover:no-underline cursor-help"
            >
              Service Accounts
            </span>
            <div
              id="sa-tooltip"
              role="tooltip"
              className="absolute z-10 invisible inline-block px-3 py-2 text-xs font-medium text-white transition-opacity duration-100 bg-neutral-900 rounded shadow-sm opacity-90 tooltip"
            >
              Machine accounts used to access resources without a user present
              <div className="tooltip-arrow" data-popper-arrow></div>
            </div>
          </td>
          <td className="px-6 py-4 text-center">10</td>
          <td className="px-6 py-4 text-center">No limit</td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">
            <span
              data-tooltip-target="sites-tooltip"
              data-tooltip-placement="top"
              className="underline hover:no-underline cursor-help"
            >
              Sites
            </span>
            <div
              id="sites-tooltip"
              role="tooltip"
              className="absolute z-10 invisible inline-block px-3 py-2 text-xs font-medium text-white transition-opacity duration-100 bg-neutral-900 rounded shadow-sm opacity-90 tooltip"
            >
              Sites are a collection of gateways and resources that share the
              same network connectivity context. Typically a subnet or VPC.
              <div className="tooltip-arrow" data-popper-arrow></div>
            </div>
          </td>
          <td className="px-6 py-4 text-center">3</td>
          <td className="px-6 py-4 text-center">No limit</td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">
            <span
              data-tooltip-target="admins-tooltip"
              data-tooltip-placement="top"
              className="underline hover:no-underline cursor-help"
            >
              Admins
            </span>
            <div
              id="admins-tooltip"
              role="tooltip"
              className="absolute z-10 invisible inline-block px-3 py-2 text-xs font-medium text-white transition-opacity duration-100 bg-neutral-900 rounded shadow-sm opacity-90 tooltip"
            >
              Users with account-wide access to deploy gateways, manage billing,
              and edit users, sites, or other configuration
              <div className="tooltip-arrow" data-popper-arrow></div>
            </div>
          </td>
          <td className="px-6 py-4 text-center">1</td>
          <td className="px-6 py-4 text-center">No limit</td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">
            <span
              data-tooltip-target="policies-tooltip"
              data-tooltip-placement="top"
              className="underline hover:no-underline cursor-help"
            >
              Policies
            </span>
            <div
              id="policies-tooltip"
              role="tooltip"
              className="absolute z-10 invisible inline-block px-3 py-2 text-xs font-medium text-white transition-opacity duration-100 bg-neutral-900 rounded shadow-sm opacity-90 tooltip"
            >
              Policies control access to resources (e.g. group “A” may access
              resource “B”)
              <div className="tooltip-arrow" data-popper-arrow></div>
            </div>
          </td>
          <td className="px-6 py-4 text-center">No limit</td>
          <td className="px-6 py-4 text-center">No limit</td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">
            <span
              data-tooltip-target="resources-tooltip"
              data-tooltip-placement="top"
              className="underline hover:no-underline cursor-help"
            >
              Resources
            </span>
            <div
              id="resources-tooltip"
              role="tooltip"
              className="absolute z-10 invisible inline-block px-3 py-2 text-xs font-medium text-white transition-opacity duration-100 bg-neutral-900 rounded shadow-sm opacity-90 tooltip"
            >
              Anything you wish to manage access to (e.g. database, VPC, home
              network, web server, SaaS application)
              <div className="tooltip-arrow" data-popper-arrow></div>
            </div>
          </td>
          <td className="px-6 py-4 text-center">No limit</td>
          <td className="px-6 py-4 text-center">No limit</td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">
            <span
              data-tooltip-target="devices-tooltip"
              data-tooltip-placement="top"
              className="underline hover:no-underline cursor-help"
            >
              Connected Clients
            </span>
            <div
              id="devices-tooltip"
              role="tooltip"
              className="absolute z-10 invisible inline-block px-3 py-2 text-xs font-medium text-white transition-opacity duration-100 bg-neutral-900 rounded shadow-sm opacity-90 tooltip"
            >
              Any device or machine that the Firezone client application
              connects from
              <div className="tooltip-arrow" data-popper-arrow></div>
            </div>
          </td>
          <td className="px-6 py-4 text-center">No limit</td>
          <td className="px-6 py-4 text-center">No limit</td>
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
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Cloud & local networks</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Native Firezone clients</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Split tunneling</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">DNS-based routing</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Gateway load-balancing</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Automatic gateway failover</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Global relay network</td>
          <td className="px-6 py-4 flex-wrap text-center">
            Standard performance
          </td>
          <td className="px-6 py-4 flex-wrap text-center">
            Premium performance
          </td>
        </tr>
        <tr>
          <td
            colSpan={3}
            className="px-6 pt-8 pb-4 text-lg font-semibold text-primary-450 tracking-light"
          >
            Authentication & Authorization
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Resource-level access policies</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="px-6 py-4 justify-center">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Email (OTP) authentication</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">OpenID Connect authentication</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Google Workspace sync</td>
          <td className="px-6 py-4 text-center">&#8212;</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Microsoft Entra ID sync</td>
          <td className="px-6 py-4 text-center">&#8212;</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Okta sync</td>
          <td className="px-6 py-4 text-center">&#8212;</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr>
          <td
            colSpan={3}
            className="px-6 pt-8 pb-4 text-lg font-semibold text-primary-450 tracking-light"
          >
            Security Features
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Daily key rotation</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Policy authorization logs</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">GeoIP Mapping</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr>
          <td
            colSpan={3}
            className="px-6 pt-8 pb-4 text-lg font-semibold text-primary-450 tracking-light"
          >
            Support
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Community Forums</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Community Slack</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Priority Email</td>
          <td className="px-6 py-4 text-center">&#8212;</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr className="border-b border-1 border-neutral-200">
          <td className="px-6 py-4">Dedicated Slack</td>
          <td className="px-6 py-4 text-center">&#8212;</td>
          <td className="px-6 py-4">
            <HiCheck className="mx-auto flex-shrink-0 w-5 h-5 text-neutral-900" />
          </td>
        </tr>
        <tr>
          <td></td>
          <td className="px-6 py-14">
            <Link href="/product/early-access">
              <button
                type="button"
                className="w-48 text-white font-bold tracking-tight rounded duration-0 hover:scale-105 transition transform shadow-lg text-md py-2.5 bg-accent-450 hover:bg-accent-700"
              >
                Request early access
              </button>
            </Link>
          </td>
          <td className="px-6 py-14">
            <Link href="/contact/sales">
              <button
                type="button"
                className="w-48 text-white font-bold tracking-tight rounded duration-0 hover:scale-105 transition transform shadow-lg text-md py-2.5 bg-accent-450 hover:bg-accent-700"
              >
                Request a demo
              </button>
            </Link>
          </td>
        </tr>
      </tbody>
    </table>
  );
}
