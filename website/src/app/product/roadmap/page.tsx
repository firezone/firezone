import Link from "next/link";
import CommitMarquee from "@/components/CommitMarquee";

export default function Page() {
  return (
    <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
      <div className="mx-auto max-w-screen-md">
        <h2 className="sm:justify-center mb-4 text-2xl font-extrabold tracking-tight text-neutral-900 sm:text-6xl dark:text-neutral-50">
          Firezone Roadmap
        </h2>
        <p className="mx-auto sm:text-center mb-8 max-w-2xl text-neutral-800 md:mb-12 sm:text-xl dark:text-neutral-100">
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

      <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mx-auto max-w-screen-lg bg-white">
        <div>
          <h3>Completed</h3>
        </div>
        <div>
          <h3>In Progress</h3>
        </div>
        <div>
          <h3>Planned</h3>
        </div>
      </div>

      <CommitMarquee xmlFeed="/api/github/firezone/firezone/commits/cloud.atom" />
    </div>
  );
}
