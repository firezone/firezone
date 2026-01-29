import Link from "next/link";
import Image from "next/image";

export default function Story() {
  return (
    <section className="bg-neutral-100">
      <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
        <div className="sm:text-lg">
          <h2 className="mb-12 underline justify-center md:text-5xl text-4xl tracking-tight font-extrabold text-neutral-900 leading-none">
            How it all started
          </h2>
          <p className="mb-12 text-2xl tracking-tight text-neutral-800 sm:px-16 xl:px-32">
            Founded in 2021 by Jamil Bou Kheir and Jason Gong, Firezone
            originally started as a side project to make it easier to use
            WireGuard.{" "}
            <span className="text-primary-500 font-medium">130 releases</span>{" "}
            and <span className="text-primary-500 font-medium">15,000+</span>{" "}
            {"users later, it's grown into something much more."}
          </p>
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-12">
          <div className="max-w-xl flex">
            <Image
              src="/images/story.png"
              alt="Firezone story"
              width={1000}
              height={1000}
              className="my-auto"
            />
          </div>
          <div className="max-w-xl">
            <ol className="relative border-s border-neutral-400">
              <li className="mb-12 ms-4">
                <div className="absolute w-3 h-3 bg-neutral-400 rounded-full mt-1.5 -start-1.5 border border-white"></div>
                <time className="mb-1 text-sm font-normal leading-none text-neutral-800">
                  April 2020
                </time>
                <h3 className="text-lg font-semibold text-neutral-800">
                  First commit
                </h3>
                <p className="mb-4 text-base font-normal text-neutral-800">
                  The{" "}
                  <Link
                    href={
                      new URL(
                        "https://github.com/firezone/firezone/tree/d049b006f6b530d8aa6f936441ffadd86e02a574"
                      )
                    }
                    className="hover:underline text-accent-500"
                  >
                    initial commit
                  </Link>{" "}
                  of the Firezone codebase is made.
                </p>
              </li>
              <li className="mb-12 ms-4">
                <div className="absolute w-3 h-3 bg-neutral-400 rounded-full mt-1.5 -start-1.5 border border-white"></div>
                <time className="mb-1 text-sm font-normal leading-none text-neutral-800">
                  September 2021
                </time>
                <h3 className="text-lg font-semibold text-neutral-800 ">
                  First public release
                </h3>
                <p className="mb-4 text-base font-normal text-neutral-800">
                  The first public release of Firezone is{" "}
                  <Link
                    className="hover:underline text-accent-500"
                    href={
                      new URL("https://news.ycombinator.com/item?id=28683231")
                    }
                  >
                    announced
                  </Link>{" "}
                  on Hacker News.
                </p>
              </li>
              <li className="mb-12 ms-4">
                <div className="absolute w-3 h-3 bg-neutral-400 rounded-full mt-1.5 -start-1.5 border border-white"></div>
                <time className="mb-1 text-sm font-normal leading-none text-neutral-800">
                  October 2021
                </time>
                <h3 className="text-lg font-semibold text-neutral-800 ">
                  YC acceptance
                </h3>
                <p className="text-base font-normal text-neutral-800">
                  {"Firezone is accepted into YC's Winter 2022 batch."}
                </p>
              </li>
              <li className="mb-12 ms-4">
                <div className="absolute w-3 h-3 bg-neutral-400 rounded-full mt-1.5 -start-1.5 border border-white"></div>
                <time className="mb-1 text-sm font-normal leading-none text-neutral-800">
                  April 2022
                </time>
                <h3 className="text-lg font-semibold text-neutral-800 ">
                  Funding
                </h3>
                <p className="text-base font-normal text-neutral-800">
                  Firezone graduates from the YC Winter 2022 batch and raises a
                  seed round.
                </p>
              </li>
              <li className="ms-4">
                <div className="absolute w-3 h-3 bg-neutral-400 rounded-full mt-1.5 -start-1.5 border border-white"></div>
                <time className="mb-1 text-sm font-normal leading-none text-neutral-800">
                  April 2024
                </time>
                <h3 className="text-lg font-semibold text-neutral-800 ">
                  1.0 Launch
                </h3>
                <p className="text-base font-normal text-neutral-800">
                  Firezone launches the first commercial version of its
                  innovative zero-trust product.
                </p>
              </li>
            </ol>
          </div>
        </div>
      </div>
    </section>
  );
}
