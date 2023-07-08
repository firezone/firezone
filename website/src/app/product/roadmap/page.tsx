import Link from "next/link";
import CommitMarquee from "@/components/CommitMarquee";
import ActionLink from "@/components/ActionLink";

export default function Page() {
  return (
    <div className="bg-neutral-100">
      <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
        <div className="mx-auto max-w-screen-md">
          <h1 className="sm:justify-center mb-4 text-2xl font-extrabold tracking-tight text-neutral-900 sm:text-6xl dark:text-neutral-50">
            Firezone Roadmap
          </h1>
          <p className="mx-auto sm:text-center mb-8 max-w-2xl text-neutral-900 md:mb-12 sm:text-xl dark:text-neutral-100">
            Take a peek below to learn what we're working on and how you can get
            involved.
          </p>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mx-auto max-w-screen-lg">
          <div className="p-2">
            <h3 className="justify-center text-neutral-900 tracking-tight font-semibold text-xl">
              Completed
            </h3>
            <div className="flex flex-col">
              <ul>
                <li>Initial release of Firezone</li>
              </ul>
            </div>
          </div>
          <div className="p-2">
            <h3 className="justify-center text-neutral-900 tracking-tight font-semibold text-xl">
              In Progress
            </h3>
            <div className="flex flex-col">
              <ul>
                <li>Firezone 1.0</li>
              </ul>
            </div>
          </div>
          <div className="p-2">
            <h3 className="justify-center text-neutral-900 tracking-tight font-semibold text-xl">
              Planned
            </h3>
            <div className="flex flex-col">
              <ul>
                <li>Windows Client</li>
              </ul>
            </div>
          </div>
        </div>
      </div>
      <div className="border-t border-neutral-200 mx-auto bg-gradient-to-b from-white to-neutral-100 py-14">
        <h2 className="sm:justify-center mb-4 text-2xl font-extrabold tracking-tight text-neutral-900 sm:text-4xl dark:text-neutral-50">
          <span>We're building Firezone</span>{" "}
          <span className="underline">in the open.</span>
        </h2>
        <p className="mx-auto max-w-2xl text-neutral-900 sm:text-center mb-4 sm:text-xl">
          We're open source because we believe better transparency leads to
          better security. After all, how can you trust what you can't see?
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
    </div>
  );
}
