"use client";

import { Metadata } from "next";
import Link from "next/link";
import CommitMarquee from "@/components/CommitMarquee";
import ActionLink from "@/components/ActionLink";
import JoinOurCommunity from "@/components/JoinOurCommunity";
import { HiMegaphone, HiBeaker } from "react-icons/hi2";
import { XMLParser } from "fast-xml-parser";
import { useState, useEffect } from "react";
import GitHubHtml from "@/components/GitHubHtml";

export const metadata: Metadata = {
  title: "Product Roadmap • Firezone",
  description: "Recently shipped, in progress, and future updates to Firezone.",
};

function RoadmapItem({
  title,
  href,
  type,
  date,
  entryId,
  children,
}: {
  href: string;
  title: string;
  type: string;
  date?: string;
  entryId?: string;
  children: React.ReactNode;
}) {
  function badge(type: string) {
    switch (type) {
      case "release":
        return (
          <span className="bg-accent-600 text-white text-xs font-semibold px-2.5 py-0.5 rounded">
            {type}
          </span>
        );
      case "1.0":
      case "feature":
        return (
          <span className="bg-primary-450 text-white text-xs font-semibold px-2.5 py-0.5 rounded">
            {type}
          </span>
        );
      case "refactor":
      case "website":
        return (
          <span className="bg-neutral-800 text-white text-xs font-semibold px-2.5 py-0.5 rounded">
            {type}
          </span>
        );
      case "docs":
        return (
          <span className="bg-neutral-100 text-neutral-800 text-xs font-semibold px-2.5 py-0.5 rounded">
            {type}
          </span>
        );
    }
  }
  return (
    <li
      key={entryId}
      className="shadow-sm bg-white rounded-sm shadow-sm p-4 mb-4 hover:shadow-md"
    >
      <h5 className="text-lg font-semibold">
        <Link
          href={href}
          className="text-accent-500 underline hover:no-underline"
        >
          {title}
        </Link>
      </h5>
      <div className="pb-4">{children}</div>
      <div className="flex items-center justify-between">
        {date ? (
          <span className="text-xs font-semibold px-2.5 py-0.5 bg-neutral-200 text-neutral-800">
            {new Date(date!).toDateString()}
          </span>
        ) : (
          <span></span>
        )}
        {badge(type)}
      </div>
    </li>
  );
}

export default function Page() {
  const parser = new XMLParser({ ignoreAttributes: false });
  const [xml, setXml] = useState<any>({ feed: { entry: [] } });

  useEffect(() => {
    fetch("/api/github/firezone/firezone/releases.atom")
      .then((response) => response.text())
      .then((str) => parser.parse(str))
      .then((data) => {
        setXml(data);
      })
      .catch((error) => console.error(error));
  }, []);

  return (
    <div className="bg-neutral-100">
      <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
        <div className="mx-auto max-w-screen-md">
          <h1 className="sm:justify-center mb-4 text-2xl font-extrabold tracking-tight text-neutral-900 sm:text-6xl ">
            Product Roadmap
          </h1>
          <h2 className="mx-auto sm:text-center mb-8 max-w-2xl tracking-tight font-medium text-neutral-900 md:mb-12 sm:text-xl ">
            Take a peek below to learn what we're working on and how you can get
            involved.
          </h2>
        </div>

        <div className="grid md:grid-cols-3 mx-auto max-w-screen-lg divide-x">
          <div className="p-6">
            <h3 className="text-neutral-900 tracking-tight font-bold text-2xl mb-4">
              Shipped
            </h3>
            <p className="text-lg text-neutral-900  mb-6">
              Updates we've recently shipped.
            </p>
            <div className="mb-4">
              <h4 className="border-b border-neutral-200 mb-2 text-xl tracking-tight font-semibold text-neutral-800">
                Recent Releases
              </h4>
              <ul className="flex flex-col">
                {xml.feed.entry.slice(0, 3).map((entry: any) => {
                  return (
                    <RoadmapItem
                      entryId={entry.id}
                      title={entry.title}
                      href={entry.link["@_href"]}
                      type="release"
                      date={entry.updated}
                    >
                      <GitHubHtml html={entry.content["#text"]} />
                    </RoadmapItem>
                  );
                })}
              </ul>
            </div>
            {/* TODO: Consider automating this with the GitHub API */}
            <div className="mb-4">
              <h4 className="border-b border-neutral-200 mb-2 text-xl tracking-tight font-semibold text-neutral-800">
                Website / Docs
              </h4>
              <ul className="flex flex-col">
                <RoadmapItem
                  title="1.0 early access page"
                  href="https://github.com/firezone/firezone/pull/1733"
                  type="website"
                  date="2023-07-06T17:56:03Z"
                >
                  We've added a new{" "}
                  <Link
                    href="/product/early-access"
                    className="text-accent-500 underline hover:no-underline"
                  >
                    early access page
                  </Link>{" "}
                  to allow users to sign up to test new Firezone features and
                  releases.
                </RoadmapItem>
                <RoadmapItem
                  title="Team page"
                  href="https://github.com/firezone/firezone/pull/1731"
                  type="website"
                  date="2023-07-05T16:08:36Z"
                >
                  A new{" "}
                  <Link
                    href="/team"
                    className="text-accent-500 underline hover:no-underline"
                  >
                    team page
                  </Link>{" "}
                  has been added to showcase the team behind Firezone.
                </RoadmapItem>
                <RoadmapItem
                  title="Brand colors"
                  href="https://github.com/firezone/firezone/pull/1728"
                  type="website"
                  date="2023-07-03T23:32:41Z"
                >
                  Our website now sports a new color palette, font, and spacing
                  consistent with the Firezone product.
                </RoadmapItem>
              </ul>
            </div>
          </div>
          <div className="p-6">
            <h3 className="text-neutral-900 tracking-tight font-bold text-2xl mb-4">
              In progress
            </h3>
            <p className="text-lg text-neutral-900  mb-6">
              Things we're actively working on and plan to ship in the next
              release or two.
            </p>
            <div className="mb-4">
              <div className="p-2 bg-primary-100 border border-primary-200 mb-4">
                <HiBeaker className="inline-block w-4 h-4 mr-1 text-primary-450" />
                <Link
                  href="/product/early-access"
                  className="text-accent-500 underline hover:no-underline"
                >
                  Sign up for early access
                </Link>{" "}
                to test new Firezone features and releases.
              </div>
              <h4 className="border-b border-neutral-200 mb-2 text-xl tracking-tight font-semibold text-neutral-800">
                Firezone 1.0
              </h4>
              <ul className="flex flex-col">
                <RoadmapItem
                  title="Automated provisioning"
                  href="https://github.com/firezone/firezone/issues/1437"
                  type="feature"
                >
                  Automated user and group provisioning via just-in-time (JIT)
                  provisioning or SCIM 2.0.
                </RoadmapItem>
                <RoadmapItem
                  title="Authentication overhaul"
                  href="https://github.com/firezone/firezone/issues/1123"
                  type="refactor"
                >
                  More robust support for SAML 2.0, OIDC, and magic link
                  authentication methods.
                </RoadmapItem>
                <RoadmapItem
                  title="Group-based access policies"
                  href="https://github.com/firezone/firezone/issues/1157"
                  type="feature"
                >
                  Control access to protected Resources on a per-group basis.
                </RoadmapItem>
                <RoadmapItem
                  title="Apple client"
                  href="https://github.com/firezone/firezone/issues/1763"
                  type="feature"
                >
                  Native Firezone client for macOS and iOS.
                </RoadmapItem>
                <RoadmapItem
                  title="NAT traversal"
                  href="https://github.com/firezone/firezone/issues/1765"
                  type="feature"
                >
                  Automatic holepunching and STUN/TURN discovery for Clients and
                  Gateways.
                </RoadmapItem>
                <RoadmapItem
                  title="Split DNS"
                  href="https://github.com/firezone/firezone/issues/1158"
                  type="feature"
                >
                  Resolve DNS queries for protected Resources using Firezone's
                  built-in DNS while forwarding other queries to a configurable
                  upstream DNS server.
                </RoadmapItem>
                <RoadmapItem
                  title="Android client"
                  href="https://github.com/firezone/firezone/issues/1767"
                  type="feature"
                >
                  Native Firezone client for Android.
                </RoadmapItem>
                <RoadmapItem
                  title="High availability"
                  href="https://github.com/firezone/firezone/issues/897"
                  type="feature"
                >
                  Support for High availability (HA) deployments of the Firezone
                  Gateway.
                </RoadmapItem>
              </ul>
            </div>
          </div>
          <div className="p-6">
            <h3 className="text-neutral-900 tracking-tight font-bold text-2xl mb-4">
              Under consideration
            </h3>
            <p className="text-lg text-neutral-900  mb-6">
              Things we're still investigating, architecting, or in the process
              of prioritizing.{" "}
              <span className="font-semibold">(feedback welcome!)</span>
            </p>
            <ul className="flex flex-col">
              <RoadmapItem
                title="Windows client"
                href="https://github.com/firezone/firezone/issues/1768"
                type="feature"
              >
                Native Firezone client for Windows.
              </RoadmapItem>
              <RoadmapItem
                title="Service  accounts"
                href="https://github.com/firezone/firezone/issues/1770"
                type="feature"
              >
                Support for service accounts to allow automated access to
                protected Resources. Requires headless clients for
                Linux/Windows.
              </RoadmapItem>
              <RoadmapItem
                title="Linux client"
                href="https://github.com/firezone/firezone/issues/1762"
                type="feature"
              >
                Native Firezone client for Linux.
              </RoadmapItem>
              <RoadmapItem
                title="Audit logging"
                href="https://github.com/firezone/firezone/issues/949"
                type="feature"
              >
                Log admin portal configuration changes and end-user access to
                protected Resources to achieve compliance with regulatory
                requirements.
              </RoadmapItem>
            </ul>
          </div>
        </div>
      </div>
      <div className="border border-primary-200 bg-primary-100">
        <div className="mx-auto max-w-screen-lg grid text-center md:grid-cols-2 text-lg sm:text-xl py-3 sm:py-6">
          <div>
            <HiMegaphone className="inline-flex h-5 w-5 mr-2 text-primary-450" />
            Want to stay updated on our progress?
          </div>
          <div>
            <ActionLink
              href="/product/newsletter"
              className="ml-8 inline-flex text-accent-500 underline hover:no-underline"
            >
              Subscribe to our newsletter.
            </ActionLink>
          </div>
        </div>
      </div>
      <div className="border-t border-neutral-200 mx-auto bg-gradient-to-b from-white to-neutral-100 pt-14">
        <h2 className="ml-2 sm:justify-center flex-wrap mb-4 text-4xl font-extrabold tracking-tight text-neutral-900">
          <span>We're building Firezone</span>{" "}
          <span className="text-primary-450 underline">in the open.</span>
        </h2>
        <p className="sm:mx-auto ml-2 max-w-xl text-neutral-900 sm:text-center mb-4 text-lg sm:text-xl">
          We're open source because we believe <i>better transparency</i> leads
          to <i>better security</i>. After all, how can you trust what you can't
          see?
        </p>
        <p className="mx-auto mb-4 sm:mb-8 text-lg sm:text-xl">
          <ActionLink
            href="https://github.com/firezone/firezone/pulls"
            className="ml-2 flex text-lg items-center sm:justify-center text-accent-500 underline hover:no-underline"
          >
            See what we're working on
          </ActionLink>
          .
        </p>
        <CommitMarquee xmlFeed="/api/github/firezone/firezone/commits/main.atom" />
      </div>

      <JoinOurCommunity />
    </div>
  );
}
