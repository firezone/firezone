import { Metadata } from "next";
import gravatar from "@/lib/gravatar";
import Link from "next/link";
import Image from "next/image";
import NewsletterSignup from "@/components/NewsletterSignup";
import SummaryCard from "@/components/Blog/SummaryCard";

export const metadata: Metadata = {
  title: "Blog • Firezone",
  description: "Announcements, insights, and more from the Firezone team.",
};

export default function Page() {
  return (
    <section>
      <div className="py-6 px-4 sm:py-8 sm:px-6 md:py-10 md:px-8 lg:py-12 lg:px-10 mx-auto max-w-screen-lg w-full">
        <h1 className="text-4xl sm:text-5xl md:text-6xl lg:text-7xl xl:text-8xl font-bold tracking-tight mt-8">
          Blog
        </h1>
        <p className="text-lg md:text-xl lg:text-2xl mt-4 md:mt-6 lg:mt-8 tracking-tight">
          Announcements, insights, and more from the Firezone team.
        </p>
        <div className="mt-14 grid divide-y">
          <SummaryCard
            title="June 2024 update"
            date="June 21, 2024"
            href="/blog/jun-2024-update"
            authorName="Jamil Bou Kheir"
            authorAvatarSrc={gravatar("jamil@firezone.dev")}
            type="Announcement"
          >
            <div className="mb-2">
              <div className="mb-2">In this update:</div>
              <ul className="space-y-2 list-inside list-disc ml-4">
                <li>
                  <strong>New feature:</strong> Conditional access policies
                </li>
                <li>
                  <strong>New feature:</strong> Directory sync support for
                  JumpCloud
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
                  <Link href="/support" className="text-accent-500 underline">
                    support
                  </Link>{" "}
                  page for getting help with Firezone.
                </li>
                <li>
                  New{" "}
                  <Link href="/changelog" className="text-accent-500 underline">
                    changelog
                  </Link>{" "}
                  page with release notes for every component we ship.
                </li>
              </ul>
            </div>
          </SummaryCard>
          <SummaryCard
            title="Improving reliability for DNS Resources"
            date="June 20, 2024"
            href="/blog/improving-reliability-for-dns-resources"
            authorName="Jamil Bou Kheir"
            authorAvatarSrc={gravatar("jamil@firezone.dev")}
            type="Announcement"
          >
            <p className="mb-2">
              We're making some changes to the way DNS Resources are routed in
              Firezone. These changes will be coming in Client and Gateway
              versions 1.1 and later. Continue reading to understand how these
              changes will affect your network and what you need to do to take
              advantage of them.
            </p>
          </SummaryCard>
          <SummaryCard
            title="Using Tauri to build a cross-platform security app"
            date="June 11, 2024"
            href="/blog/using-tauri"
            authorName="ReactorScram"
            authorAvatarSrc="/images/avatars/reactorscram.png"
            type="Learn"
          >
            <p className="mb-2">
              We chose Tauri over other frameworks because it was the fastest
              way to get the Firezone Client working on Linux and Windows.
            </p>
          </SummaryCard>
          <SummaryCard
            title="How DNS works in Firezone"
            date="May 8, 2024"
            href="/blog/how-dns-works-in-firezone"
            authorName="Gabriel Steinberg"
            authorAvatarSrc={gravatar("gabriel@firezone.dev")}
            type="Learn"
          >
            <p className="mb-2">
              Firezone's approach to DNS works a bit differently than one might
              expect. One question we often get from new users is, "why do my
              DNS Resources resolve to a different IP address with Firezone
              enabled?". Great question -- read on to find out.
            </p>
          </SummaryCard>
          <SummaryCard
            title="May 2024 update"
            date="May 1, 2024"
            href="/blog/may-2024-update"
            authorName="Jamil Bou Kheir"
            authorAvatarSrc={gravatar("jamil@firezone.dev")}
            type="Announcement"
          >
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
          </SummaryCard>
          <SummaryCard
            title="April 2024 update: GA"
            date="April 1, 2024"
            href="/blog/apr-2024-update"
            authorName="Jamil Bou Kheir"
            authorAvatarSrc={gravatar("jamil@firezone.dev")}
            type="Announcement"
          >
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
          </SummaryCard>
          <SummaryCard
            title="March 2024 update"
            date="March 1, 2024"
            href="/blog/mar-2024-update"
            authorName="Jamil Bou Kheir"
            authorAvatarSrc={gravatar("jamil@firezone.dev")}
            type="Announcement"
          >
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
          </SummaryCard>
          <SummaryCard
            title="January 2024 update"
            date="January 1, 2024"
            href="/blog/jan-2024-update"
            authorName="Jamil Bou Kheir"
            authorAvatarSrc={gravatar("jamil@firezone.dev")}
            type="Announcement"
          >
            <p className="mb-2">Happy new year from the Firezone team!</p>

            <p>
              After a long year of building, we're incredibly excited to
              announce 1.0 beta testing for Apple and Android platforms.
              Firezone 1.0 is an entirely new product with a brand new
              architecture that includes many of the features you've been asking
              for. To summarize just a few:
            </p>
          </SummaryCard>
          <SummaryCard
            title="Enterprises choose open source"
            date="December 6, 2023"
            href="/blog/enterprises-choose-open-source"
            authorName="Jeff Spencer"
            authorAvatarSrc={gravatar("jeff@firezone.dev")}
            type="Insights"
          >
            <p>
              More enterprises are turning to open source software (OSS) to
              reduce costs, improve efficiency, and extend their competitive
              advantage. The core technologies chosen by organizations often
              persist for decades, so decisions that IT leaders make today are
              bound to affect their organizations’ ability to function and adapt
              in the future — whether that’s one year, or 10.
            </p>
          </SummaryCard>
          <SummaryCard
            title="Secure remote access makes remote work a win-win"
            date="November 17, 2023"
            href="/blog/secure-access"
            authorName="Jeff Spencer"
            authorAvatarSrc={gravatar("jeff@firezone.dev")}
            type="Insights"
          >
            <p>
              The number of employees working remotely is accelerating, so
              secure remote access should be a large part of any organization’s
              cybersecurity strategy. Secure remote access lets remote and
              hybrid employees work from anywhere in the world, on any device,
              without compromising your organization’s network, data, and system
              security.
            </p>
          </SummaryCard>
          <SummaryCard
            title="Firezone 1.0"
            date="July 15, 2023"
            href="/blog/firezone-1-0"
            authorName="Jamil Bou Kheir"
            authorAvatarSrc={gravatar("jamil@firezone.dev")}
            type="Announcement"
          >
            <p className="mb-2 font-semibold">
              Firezone comes from humble roots.
            </p>
            <p>
              When we launched on Hacker News nearly two years ago, we never
              envisioned Firezone to be more than a simple tool for managing
              your WireGuard configurations.
            </p>
          </SummaryCard>
          <SummaryCard
            title="Release 0.6.0"
            date="October 17, 2022"
            href="/blog/release-0-6-0"
            authorName="Jamil Bou Kheir"
            authorAvatarSrc={gravatar("jamil@firezone.dev")}
            type="Announcement"
          >
            Today, I'm excited to announce we've closed the first public issue
            on our GitHub repository, more than a year after it was originally
            opened: Containerization support! We're also releasing preliminary
            support for SAML 2.0 identity providers like Okta and OneLogin.
          </SummaryCard>
          <div></div>
          <SummaryCard
            title="Release 0.5.0"
            date="July 25, 2022"
            href="/blog/release-0-5-0"
            authorName="Jamil Bou Kheir"
            authorAvatarSrc={gravatar("jamil@firezone.dev")}
            type="Announcement"
          >
            As the first post on our new blog, we thought it'd be fitting to
            kick things off with a release announcement. So without further ado,
            we're excited to announce: Firezone 0.5.0 is here! It's packed with
            new features, bug fixes, and other improvements — more on that
            below.
          </SummaryCard>
        </div>
      </div>
    </section>
  );
}
