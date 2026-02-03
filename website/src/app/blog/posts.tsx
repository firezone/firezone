"use client";

import { useState } from "react";
import Link from "next/link";
import SummaryCard from "@/components/Blog/SummaryCard";
import Pills from "@/components/Pills";
import gravatar from "@/lib/gravatar";
import { Route } from "next";
import { Badge } from "@/components/Badges";

export default function Posts() {
  const [filters, setFilters] = useState("All Posts");
  const posts = [
    {
      title: "December 2025 Devlog",
      date: "December 31, 2025",
      href: "/blog/devlog/2025-12",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Engineering",
      description: (
        <p className="mb-2">
          Major portal architecture refactor collapsing umbrella apps,
          authentication system restructuring, relay connection reliability
          improvements, and database performance optimizations.
        </p>
      ),
    },
    {
      title: "November 2025 Devlog",
      date: "November 30, 2025",
      href: "/blog/devlog/2025-11",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Engineering",
      description: (
        <p className="mb-2">
          DNS over HTTPS support, Swift 6.2 upgrade for Apple clients, Wayland
          support for the Linux GUI client, and various Gateway reliability
          improvements.
        </p>
      ),
    },
    {
      title: "Nov 28 2025 Incident Post-Mortem",
      date: "November 28, 2025",
      href: "/blog/2025-11-28-incident-post-mortem",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Announcement",
      description: (
        <p className="mb-2">
          {
            "On November 28, 2025, a PII leak incident occurred affecting a small number of user names and email addresses. This post-mortem details the incident, its impact, and the steps we're taking to prevent future occurrences."
          }
        </p>
      ),
    },
    {
      title: "Scheduled Maintenance - December 6, 2025",
      date: "November 22, 2025",
      href: "/blog/2025-12-06-scheduled-maintenance",
      authorName: "Firezone Team",
      authorAvatarSrc: "/images/logo-main-light.svg",
      type: "Announcement",
      description: (
        <p className="mb-2">
          Firezone will undergo scheduled maintenance on Saturday, December 6,
          2025 from 8:00 PM to 10:00 PM Pacific Time to roll out major
          improvements to authentication, directory sync, and user and group
          management. We expect only a few minutes of downtime.
        </p>
      ),
    },
    {
      title: "October 2025 Devlog",
      date: "October 31, 2025",
      href: "/blog/devlog/2025-10",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Engineering",
      description: (
        <p className="mb-2">
          {
            "October delivered substantial improvements to Gateway observability, Linux networking stack refinements, and new deployment mechanisms. This month's work focused on implementing comprehensive flow logging, addressing routing conflicts through tiered routing tables, and introducing native Debian packages for easier deployments."
          }
        </p>
      ),
    },
    {
      title: "September 2025 Devlog",
      date: "September 30, 2025",
      href: "/blog/devlog/2025-09",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Engineering",
      description: (
        <p className="mb-2">
          {
            "September brought significant improvements to Firezone's networking stack, administrative tooling, and cross-platform reliability. This month's work focused on optimizing relay performance through eBPF, improving DNS resolution behavior, and enhancing the admin portal's visibility into client and Gateway states."
          }
        </p>
      ),
    },

    {
      title: "Migrate your Internet Resource by March 15, 2025",
      date: "February 16, 2025",
      href: "/blog/migrate-your-internet-resource",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Announcement",
      src: "/images/blog/migrate-your-internet-resource/migrate-internet-resource.svg",
      description: (
        <p className="mb-2">
          {
            "We're making some changes to the way Internet Resources work to improve security and performance. Migrate your Internet Resources by "
          }
          <strong>March 15, 2025</strong>
          {" to avoid any interruptions."}
        </p>
      ),
    },
    {
      title: "September 2024 update",
      date: "September 2, 2024",
      href: "/blog/sep-2024-update",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Announcement",
      src: "/images/blog/sep-2024-update/sep-24-update.png",
      description: (
        <div className="mb-2">
          <div className="mb-2">In this update:</div>
          <ul className="space-y-2 list-inside list-disc ml-4">
            <li>
              <strong>New feature:</strong> Internet Resources
            </li>
            <li>
              <strong>New feature:</strong> REST API{" "}
              <Badge
                text="Beta"
                size="xs"
                textColor="blue-800"
                bgColor="blue-100"
              />
            </li>
            <li>
              <strong>New feature:</strong> Improved wildcard matching for DNS
              Resources
            </li>
            <li>
              <strong>Blog post:</strong>{" "}
              <Link
                href="/blog/sans-io"
                className="text-accent-500 underline hover:no-underline"
              >
                sans-IO: The secret to effective Rust for network services
              </Link>
            </li>
          </ul>
        </div>
      ),
    },
    {
      title: "sans-IO: The secret to effective Rust for network services",
      date: "July 2, 2024",
      href: "/blog/sans-io",
      authorName: "Thomas Eizinger",
      authorAvatarSrc: gravatar("thomas@firezone.dev"),
      type: "Learn",
      description: (
        <p className="mb-2">
          {
            "Firezone's data plane extensively uses the sans-IO design pattern. This post explains why we chose it and how you too can make use of it."
          }
        </p>
      ),
    },
    {
      title: "June 2024 update",
      date: "June 21, 2024",
      href: "/blog/jun-2024-update",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Announcement",
      src: "/images/blog/jun-2024-update/jun-24-update.png",
      description: (
        <div className="mb-2">
          <div className="mb-2">In this update:</div>
          <ul className="space-y-2 list-inside list-disc ml-4">
            <li>
              <strong>New feature:</strong> Conditional access policies
            </li>
            <li>
              <strong>Blog post:</strong>{" "}
              <Link
                href="/blog/using-tauri"
                className="text-accent-500 underline hover:no-underline"
              >
                Using Tauri to build a cross-platform security app
              </Link>
            </li>
            <li>
              <strong>Blog post:</strong>{" "}
              <Link
                href="/blog/improving-reliability-for-dns-resources"
                className="text-accent-500 underline hover:no-underline"
              >
                Improving reliability for DNS Resources
              </Link>
            </li>
            <li>
              New{" "}
              <Link
                href="/support"
                className="text-accent-500 underline hover:no-underline"
              >
                support
              </Link>{" "}
              page for getting help with Firezone.
            </li>
            <li>
              New{" "}
              <Link
                href="/changelog"
                className="text-accent-500 underline hover:no-underline"
              >
                changelog
              </Link>{" "}
              page with release notes for every component we ship.
            </li>
          </ul>
        </div>
      ),
    },
    {
      title: "Improving reliability for DNS Resources",
      date: "June 20, 2024",
      href: "/blog/improving-reliability-for-dns-resources",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Announcement",
      description: (
        <p className="mb-2">
          {
            "We're making some changes to the way DNS Resources are routed in Firezone. These changes will be coming in Client and Gateway versions 1.1 and later. Continue reading to understand how these changes will affect your network and what you need to do to take advantage of them."
          }
        </p>
      ),
    },
    {
      title: "Using Tauri to build a cross-platform security app",
      date: "June 11, 2024",
      href: "/blog/using-tauri",
      authorName: "ReactorScram",
      authorAvatarSrc: "/images/avatars/reactorscram.png",
      type: "Learn",
      description: (
        <p className="mb-2">
          We chose Tauri over other frameworks because it was the fastest way to
          get the Firezone Client working on Linux and Windows.
        </p>
      ),
    },
    {
      title: "How DNS works in Firezone",
      date: "May 8, 2024",
      href: "/blog/how-dns-works-in-firezone",
      authorName: "Gabriel Steinberg",
      authorAvatarSrc: gravatar("gabriel@firezone.dev"),
      type: "Learn",
      src: "/images/blog/how-dns-works-in-firezone/how-dns-works-in-firezone.png",
      description: (
        <p className="mb-2">
          {
            'Firezone\'s approach to DNS works a bit differently than one might expect. One question we often get from new users is, "why do my DNS Resources resolve to a different IP address with Firezone enabled?". Great question -- read on to find out.'
          }
        </p>
      ),
    },
    {
      title: "May 2024 update",
      date: "May 1, 2024",
      href: "/blog/may-2024-update",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Announcement",
      src: "/images/blog/may-2024-update/hero.webp",
      description: (
        <div className="mb-2">
          <div className="mb-2">In this update:</div>
          <ul className="space-y-2 list-inside list-disc ml-4">
            <li>
              <strong>New feature:</strong> Traffic restrictions
            </li>
            <li>
              Blog:{" "}
              <Link
                href="/blog/how-dns-works-in-firezone"
                className="text-accent-500 underline hover:no-underline"
              >
                How DNS works in Firezone
              </Link>
            </li>
            <li>Connectivity and reliability improvements</li>
          </ul>
        </div>
      ),
    },
    {
      title: "April 2024 update: GA",
      date: "April 1, 2024",
      href: "/blog/apr-2024-update",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Announcement",
      src: "/images/blog/apr-2024-update/GA.png",
      description: (
        <>
          <p className="mb-2">
            Firezone{" "}
            <Link
              href="/blog/apr-2024-update"
              className="text-accent-500 underline hover:no-underline"
            >
              1.0 GA is now available
            </Link>
            ! Also in this update:
          </p>
          <ul className="list-inside list-disc ml-4">
            <li>
              Firezone 1.0 signups are{" "}
              <Link
                href="https://app.firezone.dev/sign_up"
                className="text-accent-500 underline hover:no-underline"
              >
                now open
              </Link>
            </li>
            <li>New Team plan with self-serve billing</li>
            <li>
              Clients available for Windows, macOS, iOS, Android, and Linux
            </li>
            <li>Network roaming support</li>
          </ul>
        </>
      ),
    },
    {
      title: "March 2024 update",
      date: "March 1, 2024",
      href: "/blog/mar-2024-update",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Announcement",
      src: "/images/blog/mar-2024-update/release-1.0.0-pre.9.png",
      description: (
        <>
          {" "}
          <p className="mb-2">
            Firezone{" "}
            <Link
              href="/blog/mar-2024-update"
              className="text-accent-500 underline hover:no-underline"
            >
              1.0.0-pre.9 is released
            </Link>
            ! In this update:
          </p>
          <ul className="list-inside list-disc ml-4">
            <li>Windows and Linux betas</li>
            <li>Directory sync for Microsoft Entra ID and Okta</li>
            <li>Improved performance and stability</li>
          </ul>
        </>
      ),
    },
    {
      title: "January 2024 update",
      date: "January 1, 2024",
      href: "/blog/jan-2024-update",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Announcement",
      description: (
        <>
          <p className="mb-2">Happy new year from the Firezone team!</p>
          <p>
            {
              "After a long year of building, we're incredibly excited to announce 1.0 beta testing for Apple and Android platforms. Firezone 1.0 is an entirely new product with a brand new architecture that includes many of the features you've been asking for. To summarize just a few:"
            }
          </p>
        </>
      ),
    },
    {
      title: "Enterprises choose open source",
      date: "December 6, 2023",
      href: "/blog/enterprises-choose-open-source",
      authorName: "Jeff Spencer",
      authorAvatarSrc: gravatar("jeff@firezone.dev"),
      type: "Insights",
      description: (
        <p>
          More enterprises are turning to open source software (OSS) to reduce
          costs, improve efficiency, and extend their competitive advantage. The
          core technologies chosen by organizations often persist for decades,
          so decisions that IT leaders make today are bound to affect their
          organizations’ ability to function and adapt in the future — whether
          that’s one year, or 10.
        </p>
      ),
    },
    {
      title: "Secure remote access makes remote work a win-win",
      date: "November 17, 2023",
      href: "/blog/secure-access",
      authorName: "Jeff Spencer",
      authorAvatarSrc: gravatar("jeff@firezone.dev"),
      type: "Insights",
      description: (
        <p>
          The number of employees working remotely is accelerating, so secure
          remote access should be a large part of any organization’s
          cybersecurity strategy. Secure remote access lets remote and hybrid
          employees work from anywhere in the world, on any device, without
          compromising your organization’s network, data, and system security.
        </p>
      ),
    },
    {
      title: "Firezone 1.0",
      date: "July 15, 2023",
      href: "/blog/firezone-1-0",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Announcement",
      description: (
        <>
          <p className="mb-2 font-semibold">
            Firezone comes from humble roots.
          </p>
          <p>
            When we launched on Hacker News nearly two years ago, we never
            envisioned Firezone to be more than a simple tool for managing your
            WireGuard configurations.
          </p>
        </>
      ),
    },
    {
      title: "Release 0.6.0",
      date: "October 17, 2022",
      href: "/blog/release-0-6-0",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Announcement",
      description: (
        <p>
          {
            "Today, I'm excited to announce we've closed the first public issue on our GitHub repository, more than a year after it was originally opened: Containerization support! We're also releasing preliminary support for SAML 2.0 identity providers like Okta and OneLogin."
          }
        </p>
      ),
    },
    {
      title: "Release 0.5.0",
      date: "July 25, 2022",
      href: "/blog/release-0-5-0",
      authorName: "Jamil Bou Kheir",
      authorAvatarSrc: gravatar("jamil@firezone.dev"),
      type: "Announcement",
      description: (
        <p>
          {
            "As the first post on our new blog, we thought it'd be fitting to kick things off with a release announcement. So without further ado, we're excited to announce: Firezone 0.5.0 is here! It's packed with new features, bug fixes, and other improvements — more on that below."
          }
        </p>
      ),
    },
  ];
  const filteredPosts = posts.filter(
    (post) => filters.includes("All Posts") || filters.includes(post.type)
  );

  return (
    <>
      <div className="border-b py-6 px-4 sm:px-6 md:py-4 md:px-8 lg:px-10 mx-auto max-w-screen-lg w-full">
        <Pills
          options={[
            "All Posts",
            "Announcement",
            "Engineering",
            "Learn",
            "Insights",
          ]}
          filters={filters}
          setFilters={setFilters}
        />
      </div>
      <div className="mx-auto max-w-screen-lg w-full">
        <p className="px-12 pt-6 pb-4 text-neutral-600 font-semibold text-lg">
          {filteredPosts.length + " results"}
        </p>
        <div className="grid divide-y space-y-8">
          {filteredPosts.map((post, index) => (
            <SummaryCard
              key={index}
              title={post.title}
              date={post.date}
              href={post.href as Route<string>}
              authorName={post.authorName}
              authorAvatarSrc={post.authorAvatarSrc}
              type={post.type}
              src={post.src}
            >
              {post.description}
            </SummaryCard>
          ))}
        </div>
      </div>
    </>
  );
}
