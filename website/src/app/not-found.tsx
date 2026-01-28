import Link from "next/link";

export default function NotFound() {
  return (
    <section className="bg-neutral-100 h-max pt-24">
      <div className="py-8 px-4 mx-auto max-w-screen-xl">
        <div className="mx-auto max-w-screen-xs text-center">
          <h1 className="mb-4 text-4xl justify-center tracking-tight font-extrabold text-neutral-900">
            Page not found.
          </h1>
          <p className="mb-4 text-lg text-neutral-900">
            Sorry, but the page you were looking for cannot be found.
          </p>
          <p className="mb-4 text-lg text-neutral-900">
            You can go{" "}
            <Link
              href="/"
              className="inline-flex text-accent-500 underline hover:no-underline"
            >
              back to the home page
            </Link>
            , the{" "}
            <Link
              href="/blog"
              className="inline-flex text-accent-500 underline hover:no-underline"
            >
              blog home
            </Link>
            , the{" "}
            <Link
              href="/kb"
              className="inline-flex text-accent-500 underline hover:no-underline"
            >
              docs home
            </Link>
            , or{" "}
            <Link
              href="mailto:help@firezone.dev"
              className="text-accent-500 underline hover:no-underline"
            >
              contact us
            </Link>{" "}
            {"if you're still having trouble."}
          </p>
        </div>
      </div>
    </section>
  );
}
