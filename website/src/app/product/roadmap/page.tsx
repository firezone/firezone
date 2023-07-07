import Link from "next/link";
import CommitMarquee from "@/components/CommitMarquee";

export default function Page() {
  return (
    <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
      <div className="mx-auto max-w-screen-md sm:text-center">
        <h2 className="justify-center mb-4 text-2xl font-extrabold tracking-tight text-neutral-900 sm:text-6xl dark:text-neutral-50">
          Firezone Roadmap
        </h2>
        <p className="mx-auto mb-8 max-w-2xl text-neutral-800 md:mb-12 sm:text-xl dark:text-neutral-100">
          We're building Firezone{" "}
          <Link
            href="https://github.com/firezone/firezone"
            className="text-accent-500 underline hover:no-underline"
          >
            in the open
          </Link>
          . Take a peek below to learn what we're working on and how you can get
          involved.
        </p>
      </div>

      <CommitMarquee xmlFeed="/api/github/firezone/firezone/commits/cloud.atom" />
    </div>
  );
}
