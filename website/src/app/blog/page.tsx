import gravatar from "@/lib/gravatar";
import Link from "next/link";
import Image from "next/image";
import { ArrowRightIcon } from "@heroicons/react/20/solid";
import NewsletterSignup from "@/components/NewsletterSignup";

export default function Page() {
  return (
    <section className="bg-white dark:bg-gray-900">
      <div className="bg-violet-50 mx-auto w-screen text-center">
        <Image
          alt="Firezone logo"
          width={250}
          height={250}
          src="/images/logo-main.svg"
          className="py-12 mx-auto"
        />
      </div>
      <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
        <div className="mx-auto max-w-screen-sm text-center lg:mb-16 mb-8">
          <h2 className="justify-center mb-4 text-3xl lg:text-4xl tracking-tight font-extrabold text-gray-900 dark:text-white">
            Firezone Blog
          </h2>
          <p className="font-light text-gray-500 sm:text-xl dark:text-gray-400">
            Announcements, tutorials, and more from the Firezone team.
          </p>
        </div>
        <div className="grid gap-8 lg:grid-cols-2">
          <article className="p-6 bg-white rounded-lg border border-gray-200 shadow-md dark:bg-gray-800 dark:border-gray-700">
            <div className="flex justify-between items-center mb-5 text-gray-500">
              <span className="bg-primary-100 text-primary-800 text-xs font-medium inline-flex items-center px-2.5 py-0.5 rounded dark:bg-primary-200 dark:text-primary-800">
                <svg
                  className="mr-1 w-3 h-3"
                  fill="currentColor"
                  viewBox="0 0 20 20"
                  xmlns="http://www.w3.org/2000/svg"
                >
                  <path
                    fillRule="evenodd"
                    d="M2 5a2 2 0 012-2h8a2 2 0 012 2v10a2 2 0 002 2H4a2 2 0 01-2-2V5zm3 1h6v4H5V6zm6 6H5v2h6v-2z"
                    clipRule="evenodd"
                  ></path>
                  <path d="M15 7h1a2 2 0 012 2v5.5a1.5 1.5 0 01-3 0V7z"></path>
                </svg>
                Announcement
              </span>
              <span className="text-sm">October 17, 2022</span>
            </div>
            <h2 className="mb-2 text-2xl font-bold tracking-tight text-gray-900 dark:text-white">
              <Link href="/blog/release-0-6-0">Release 0.6.0</Link>
            </h2>
            <p className="mb-5 font-light text-gray-500 dark:text-gray-400">
              Today, I'm excited to announce we've closed the{" "}
              <Link href="https://github.com/firezone/firezone/issues/260">
                first public issue{" "}
              </Link>
              on our GitHub repository, more than a year after it was originally
              opened: Containerization support! We're also releasing preliminary
              support for SAML 2.0 identity providers like Okta and OneLogin.
            </p>
            <div className="flex justify-between items-center">
              <div className="flex items-center space-x-4">
                <Image
                  width={28}
                  height={28}
                  className="w-7 h-7 rounded-full"
                  src={gravatar("jamil@firezone.dev")}
                  alt="Jamil Bou Kheir avatar"
                />
                <span className="font-medium dark:text-white">
                  Jamil Bou Kheir
                </span>
              </div>
              <Link
                href="/blog/release-0-6-0"
                className="inline-flex items-center font-medium text-primary-600 dark:text-primary-500 hover:underline"
              >
                Read more
                <ArrowRightIcon className="ml-2 w-4 h-4" />
              </Link>
            </div>
          </article>
          <article className="p-6 bg-white rounded-lg border border-gray-200 shadow-md dark:bg-gray-800 dark:border-gray-700">
            <div className="flex justify-between items-center mb-5 text-gray-500">
              <span className="bg-primary-100 text-primary-800 text-xs font-medium inline-flex items-center px-2.5 py-0.5 rounded dark:bg-primary-200 dark:text-primary-800">
                <svg
                  className="mr-1 w-3 h-3"
                  fill="currentColor"
                  viewBox="0 0 20 20"
                  xmlns="http://www.w3.org/2000/svg"
                >
                  <path
                    fillRule="evenodd"
                    d="M2 5a2 2 0 012-2h8a2 2 0 012 2v10a2 2 0 002 2H4a2 2 0 01-2-2V5zm3 1h6v4H5V6zm6 6H5v2h6v-2z"
                    clipRule="evenodd"
                  ></path>
                  <path d="M15 7h1a2 2 0 012 2v5.5a1.5 1.5 0 01-3 0V7z"></path>
                </svg>
                Announcement
              </span>
              <span className="text-sm">July 25, 2022</span>
            </div>
            <h2 className="mb-2 text-2xl font-bold tracking-tight text-gray-900 dark:text-white">
              <Link href="/blog/release-0-5-0">Release 0.5.0</Link>
            </h2>
            <p className="mb-5 font-light text-gray-500 dark:text-gray-400">
              As the first post on our new blog, we thought it'd be fitting to
              kick things off with a release announcement. So without further
              ado, we're excited to announce: Firezone{" "}
              <Link href="https://github.com/firezone/firezone/releases">
                0.5.0 is here
              </Link>
              ! It's packed with new features, bug fixes, and other improvements
              — more on that below.
            </p>
            <div className="flex justify-between items-center">
              <div className="flex items-center space-x-4">
                <Image
                  width={28}
                  height={28}
                  className="w-7 h-7 rounded-full"
                  src={gravatar("jamil@firezone.dev")}
                  alt="Jamil Bou Kheir avatar"
                />
                <span className="font-medium dark:text-white">
                  Jamil Bou Kheir
                </span>
              </div>
              <Link
                href="/blog/release-0-5-0"
                className="inline-flex items-center font-medium text-primary-600 dark:text-primary-500 hover:underline"
              >
                Read more
                <ArrowRightIcon className="ml-2 w-4 h-4" />
              </Link>
            </div>
          </article>
        </div>
      </div>
      <div className="border-t border-gray-200 dark:border-gray-700 pt-8">
        <NewsletterSignup />
      </div>
    </section>
  );
}
