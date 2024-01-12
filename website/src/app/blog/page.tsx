import { Metadata } from "next";
import gravatar from "@/lib/gravatar";
import Link from "next/link";
import Image from "next/image";
import NewsletterSignup from "@/components/NewsletterSignup";
import SummaryCard from "@/components/Blog/SummaryCard";

export const metadata: Metadata = {
  title: "Blog • Firezone",
  description: "Announcements, tutorials, and more from the Firezone team.",
};

export default function Page() {
  return (
    <section className="bg-neutral-100">
      <div className="py-8 px-4 mx-auto max-w-md md:max-w-screen-md lg:py-16 lg:px-6">
        <div className="mx-auto max-w-screen-sm text-center lg:mb-16 mb-8">
          <h1 className="justify-center mb-4 text-3xl lg:text-6xl tracking-tight font-extrabold text-neutral-900 ">
            Blog
          </h1>
          <p className="text-neutral-900 text-lg sm:text-xl ">
            Announcements, insights, and more from the Firezone team.
          </p>
        </div>
        <div className="grid divide-y">
          <SummaryCard
            title="Jaunary 2024 Product Update"
            date="January 1, 2024"
            href="/blog/jan-2024-product-update"
            authorName="Jamil Bou Kheir"
            authorAvatarSrc={gravatar("jamil@firezone.dev")}
            type="Announcement"
          >
            <p>Happy new year from the Firezone team!</p>

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
