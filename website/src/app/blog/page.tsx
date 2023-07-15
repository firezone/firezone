import gravatar from "@/lib/gravatar";
import Link from "next/link";
import Image from "next/image";
import NewsletterSignup from "@/components/NewsletterSignup";
import SummaryCard from "@/components/Blog/SummaryCard";

export default function Page() {
  return (
    <section className="bg-neutral-100 ">
      <div className="py-8 px-4 mx-auto max-w-md md:max-w-screen-lg lg:py-16 lg:px-6">
        <div className="mx-auto max-w-screen-sm text-center lg:mb-16 mb-8">
          <h1 className="justify-center mb-4 text-3xl lg:text-6xl tracking-tight font-extrabold text-neutral-900 ">
            Firezone Blog
          </h1>
          <p className="text-neutral-900 text-lg sm:text-xl ">
            Announcements, tutorials, and more from the Firezone team.
          </p>
        </div>
        <div className="grid md:grid-cols-2 divide-y lg:divide-x lg:divide-y-0">
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
