"use client";

import Link from "next/link";
import CommitMarquee from "@/components/CommitMarquee";
import ActionLink from "@/components/ActionLink";
import JoinOurCommunity from "@/components/JoinOurCommunity";
import { MegaphoneIcon, ClockIcon } from "@heroicons/react/24/solid";
import { XMLParser } from "fast-xml-parser";
import { useState, useEffect } from "react";
import GitHubHtml from "@/components/GitHubHtml";

function RoadmapItem({
  title,
  content,
  date,
  href,
  type,
  entryId,
}: {
  href: string;
  content: string;
  date: string;
  title: string;
  type: string;
  entryId: string;
}) {
  function badge(type: string) {
    switch (type) {
      case "release":
        return (
          <span className="bg-accent-600 text-accent-100 text-xs font-semibold px-2.5 py-0.5 rounded">
            Release
          </span>
        );
      case "feature":
        return (
          <span className="bg-primary-100 text-primary-800 text-xs font-semibold px-2.5 py-0.5 rounded">
            Feature
          </span>
        );
      case "website":
        return (
          <span className="bg-neutral-100 text-neutral-800 text-xs font-semibold px-2.5 py-0.5 rounded">
            Website
          </span>
        );
      case "docs":
        return (
          <span className="bg-neutral-100 text-neutral-800 text-xs font-semibold px-2.5 py-0.5 rounded">
            Docs
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
      <div className="pb-4">
        <GitHubHtml html={content} />
      </div>
      <div className="flex items-center justify-between">
        <span className="text-xs font-semibold px-2.5 py-0.5 bg-neutral-200 text-neutral-800">
          <ClockIcon className="w-4 h-4 inline-block items-center mr-1" />
          {new Date(date).toDateString()}
        </span>
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
          <h1 className="sm:justify-center mb-4 text-2xl font-extrabold tracking-tight text-neutral-900 sm:text-6xl dark:text-neutral-50">
            Product Roadmap
          </h1>
          <p className="mx-auto sm:text-center mb-8 max-w-2xl text-neutral-900 md:mb-12 sm:text-xl dark:text-neutral-100">
            Take a peek below to learn what we're working on and how you can get
            involved.
          </p>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mx-auto max-w-screen-lg divide-x">
          <div className="p-6">
            <h3 className="text-neutral-900 tracking-tight font-bold text-xl mb-4">
              Shipped
            </h3>
            <p className="text-lg text-neutral-900 dark:text-neutral-50 mb-6">
              Updates we've recently shipped.
            </p>
            <h4 className="border-b border-neutral-200 mb-2 text-lg tracking-tight font-semibold text-neutral-800">
              Releases
            </h4>
            <ul className="flex flex-col">
              {xml.feed.entry.slice(0, 3).map((entry: any) => {
                return (
                  <RoadmapItem
                    entryId={entry.id}
                    content={entry.content["#text"]}
                    title={entry.title}
                    href={entry.link["@_href"]}
                    type="release"
                    date={entry.updated}
                  />
                );
              })}
            </ul>
          </div>
          <div className="p-6">
            <h3 className="text-neutral-900 tracking-tight font-bold text-xl mb-4">
              In Progress
            </h3>
            <p className="text-lg text-neutral-900 dark:text-neutral-50 mb-6">
              Things we plan to ship in the next release or two.
            </p>
            <div className="flex flex-col">
              <ul>
                <li>Firezone 1.0</li>
              </ul>
            </div>
          </div>
          <div className="p-6">
            <h3 className="text-neutral-900 tracking-tight font-bold text-xl mb-4">
              Under consideration
            </h3>
            <p className="text-lg text-neutral-900 dark:text-neutral-50 mb-6">
              Things we're still investigating and in the process of
              prioritizing.
              <br />
              <span className="font-semibold">Feedback welcome!</span>
            </p>
            <div className="flex flex-col">
              <ul>
                <li>Windows Client</li>
              </ul>
            </div>
          </div>
        </div>
      </div>
      <div className="mx-auto p-6 rounded-sm border border-5 border-primary-200 bg-primary-100 text-xl flex items-center justify-center">
        <MegaphoneIcon className="h-5 w-5 mr-2 text-primary-450" />
        Want to stay updated on our progress?
        <span className="ml-2">
          <ActionLink
            href="/product/newsletter"
            className="flex items-center justify-center text-accent-500 underline hover:no-underline"
          >
            Subscribe to our newsletter.
          </ActionLink>
        </span>
      </div>
      <div className="border-t border-neutral-200 mx-auto bg-gradient-to-b from-white to-neutral-100 pt-14">
        <h2 className="sm:justify-center mb-4 text-2xl font-extrabold tracking-tight text-neutral-900 sm:text-4xl dark:text-neutral-50">
          <span>We're building Firezone</span>{" "}
          <span className="text-primary-450 underline">in the open.</span>
        </h2>
        <p className="mx-auto max-w-2xl text-neutral-900 sm:text-center mb-4 sm:text-xl">
          We're open source because we believe <i>better transparency</i> leads
          to <i>better security</i>. After all, how can you trust what you can't
          see?
        </p>
        <p className="mx-auto mb-4 sm:mb-8 sm:text-xl">
          <ActionLink
            href="https://github.com/firezone/firezone"
            className="flex items-center justify-center text-accent-500 underline hover:no-underline"
          >
            See what we've been working on
          </ActionLink>
          .
        </p>
        <CommitMarquee xmlFeed="/api/github/firezone/firezone/commits/cloud.atom" />
      </div>

      <JoinOurCommunity />
    </div>
  );
}
