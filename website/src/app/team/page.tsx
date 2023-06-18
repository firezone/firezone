import Link from "next/link";
import Image from "next/image";
import gravatar from "@/lib/gravatar";
import { LinkedInIcon, GitHubIcon, TwitterIcon } from "@/components/Icons";

export default function Page() {
  return (
    <section className="bg-white dark:bg-gray-900">
      <div className="grid gap-16 py-8 px-4 mx-auto max-w-screen-xl lg:grid-cols-2 lg:py-16 lg:px-6">
        <div className="text-gray-500 sm:text-lg dark:text-gray-400">
          <h2 className="mb-4 text-4xl tracking-tight font-extrabold text-gray-900 dark:text-white">
            Our people make us great
          </h2>
          <p className="mb-2 md:text-lg">
            Here at Flowbite we focus on markets where technology, innovation,
            and capital can unlock long-term value.
          </p>
          <p className="font-light md:text-lg">
            Working here means you’ll interact with talented professionals, will
            be challenged to solve difficult problems and think in new and
            creative ways. Along the way, you may also make some new friends,
            have a lot of fun and enjoy opportunities.
          </p>
        </div>
        <div className="divide-y divide-gray-200 dark:divide-gray-700">
          <div className="text-gray-500 sm:text-lg dark:text-gray-400">
            <h3 className="justify-center mb-4 text-xl tracking-tight font-bold text-gray-900 dark:text-white">
              CORE TEAM
            </h3>
          </div>
          <div className="flex flex-col items-center py-8 sm:flex-row">
            <Image
              width={144}
              height={144}
              className="mx-auto mb-4 w-36 h-36 rounded-full sm:ml-0 sm:mr-6"
              src={gravatar("jamil@firezone.dev", 200)}
              alt="Jamil Avatar"
            />
            <div className="text-center sm:text-left">
              <h3 className="justify-center sm:justify-start text-xl font-bold tracking-tight text-gray-900 dark:text-white">
                Jamil Bou Kheir
              </h3>
              <span className="text-gray-500 dark:text-gray-400">
                CEO/Co-founder
              </span>
              <p className="mt-3 mb-4 max-w-sm font-light text-gray-500 dark:text-gray-400">
                Jamil drives the technical strategy of the themesberg platform
                and brand.
              </p>
              <ul className="flex justify-center space-x-4 sm:justify-start">
                <li>
                  <TwitterIcon url="https://twitter.com/jamilbk" />
                </li>
                <li>
                  <GitHubIcon url="https://github.com/jamilbk" />
                </li>
                <li>
                  <LinkedInIcon url="https://linkedin.com/in/jamilbk" />
                </li>
              </ul>
            </div>
          </div>

          <div className="flex flex-col items-center py-8 sm:flex-row">
            <Image
              width={144}
              height={144}
              className="mx-auto mb-4 w-36 h-36 rounded-full sm:ml-0 sm:mr-6"
              src="/images/avatars/gabriel.png"
              alt="Gabi Avatar"
            />
            <div className="text-center sm:text-left">
              <h3 className="justify-center sm:justify-start text-xl font-bold tracking-tight text-gray-900 dark:text-white">
                Gabriel Steinberg
              </h3>
              <span className="text-gray-500 dark:text-gray-400">
                Senior Backend Engineer
              </span>
              <p className="mt-3 mb-4 max-w-sm font-light text-gray-500 dark:text-gray-400">
                {/* TODO: bio */}
              </p>
              <ul className="flex justify-center space-x-4 sm:justify-start">
                <li>
                  <TwitterIcon url="https://twitter.com/tapingmemory" />
                </li>
                <li>
                  <GitHubIcon url="https://github.com/conectado" />
                </li>
              </ul>
            </div>
          </div>
          <div className="flex flex-col items-center py-8 sm:flex-row">
            <Image
              width={144}
              height={144}
              className="mx-auto mb-4 w-36 h-36 rounded-full sm:ml-0 sm:mr-6"
              src="/images/avatars/andrew.jpg"
              alt="Andrew Avatar"
            />
            <div className="text-center sm:text-left">
              <h3 className="justify-center sm:justify-start text-xl font-bold tracking-tight text-gray-900 dark:text-white">
                Andrew Dryga
              </h3>
              <span className="text-gray-500 dark:text-gray-400">
                Founding Engineer
              </span>
              <p className="mt-3 mb-4 max-w-sm font-light text-gray-500 dark:text-gray-400">
                {/* TODO: bio */}
              </p>
              <ul className="flex justify-center space-x-4 sm:justify-start">
                <li>
                  <TwitterIcon url="https://twitter.com/andrew_dryga" />
                </li>
                <li>
                  <GitHubIcon url="https://github.com/AndrewDryga" />
                </li>
                <li>
                  <LinkedInIcon url="https://linkedin.com/in/andrew-dryga-bb382557" />
                </li>
              </ul>
            </div>
          </div>
          <div className="flex flex-col items-center py-8 sm:flex-row">
            <Image
              width={144}
              height={144}
              className="mx-auto mb-4 w-36 h-36 rounded-full sm:ml-0 sm:mr-6"
              src={gravatar("fran@firezone.dev", 200)}
              alt="Francesca Avatar"
            />
            <div className="text-center sm:text-left">
              <h3 className="justify-center sm:justify-start text-xl font-bold tracking-tight text-gray-900 dark:text-white">
                Francesca Lovebloom
              </h3>
              <span className="text-gray-500 dark:text-gray-400">
                Senior Systems Engineer
              </span>
              <p className="mt-3 mb-4 max-w-sm font-light text-gray-500 dark:text-gray-400">
                {/* TODO: bio */}
              </p>
              <ul className="flex justify-center space-x-4 sm:justify-start">
                <li>
                  <TwitterIcon url="https://twitter.com/franlovebloom" />
                </li>
                <li>
                  <GitHubIcon url="https://github.com/francesca64" />
                </li>
                <li>
                  <LinkedInIcon url="https://www.linkedin.com/in/francesca-lovebloom/" />
                </li>
              </ul>
            </div>
          </div>
          <div className="flex flex-col items-center py-8 sm:flex-row">
            <Image
              width={144}
              height={144}
              className="mx-auto mb-4 w-36 h-36 rounded-full sm:ml-0 sm:mr-6"
              src="/images/avatars/brian.png"
              alt="Brian Avatar"
            />
            <div className="text-center sm:text-left">
              <h3 className="justify-center sm:justify-start text-xl font-bold tracking-tight text-gray-900 dark:text-white">
                Brian Manifold
              </h3>
              <span className="text-gray-500 dark:text-gray-400">
                Senior Fullstack Engineer
              </span>
              <p className="mt-3 mb-4 max-w-sm font-light text-gray-500 dark:text-gray-400">
                {/* TODO: bio */}
              </p>
              <ul className="flex justify-center space-x-4 sm:justify-start">
                <li>
                  <GitHubIcon url="https://github.com/bmanifold" />
                </li>
                <li>
                  <LinkedInIcon url="https://www.linkedin.com/in/brian-manifold-536a0a3a/" />
                </li>
              </ul>
            </div>
          </div>
          <div className="text-gray-500 sm:text-lg dark:text-gray-400">
            <h3 className="justify-center py-8 text-xl tracking-tight font-bold text-gray-900 dark:text-white">
              ADVISORS & CONSULTANTS
            </h3>
          </div>
          <div className="flex flex-col items-center py-8 sm:flex-row">
            <Image
              width={144}
              height={144}
              className="mx-auto mb-4 w-36 h-36 rounded-full sm:ml-0 sm:mr-6"
              src="/images/avatars/blake.jpeg"
              alt="Blake Avatar"
            />
            <div className="text-center sm:text-left">
              <h3 className="justify-center sm:justify-start text-xl font-bold tracking-tight text-gray-900 dark:text-white">
                Blake Hitchcock
              </h3>
              <span className="text-gray-500 dark:text-gray-400">
                Technical Advisor
              </span>
              <p className="mt-3 mb-4 max-w-sm font-light text-gray-500 dark:text-gray-400">
                {/* TODO: bio */}
              </p>
              <ul className="flex justify-center space-x-4 sm:justify-start">
                <li>
                  <GitHubIcon url="https://github.com/rbhitchcock" />
                </li>
                <li>
                  <LinkedInIcon url="https://www.linkedin.com/in/rblakehitchcock" />
                </li>
              </ul>
            </div>
          </div>
          <div className="flex flex-col items-center py-8 sm:flex-row">
            <Image
              width={144}
              height={144}
              className="mx-auto mb-4 w-36 h-36 rounded-full sm:ml-0 sm:mr-6"
              src="/images/avatars/thomas.jpeg"
              alt="Thomas Avatar"
            />
            <div className="text-center sm:text-left">
              <h3 className="justify-center sm:justify-start text-xl font-bold tracking-tight text-gray-900 dark:text-white">
                Thomas Eizinger
              </h3>
              <span className="text-gray-500 dark:text-gray-400">
                Technical Consultant
              </span>
              <p className="mt-3 mb-4 max-w-sm font-light text-gray-500 dark:text-gray-400">
                {/* TODO: bio */}
              </p>
              <ul className="flex justify-center space-x-4 sm:justify-start">
                <li>
                  <TwitterIcon url="https://twitter.com/oetzn" />
                </li>
                <li>
                  <GitHubIcon url="https://github.com/thomaseizinger" />
                </li>
                <li>
                  <LinkedInIcon url="https://www.linkedin.com/in/thomas-eizinger" />
                </li>
              </ul>
            </div>
          </div>
          <div className="flex flex-col items-center py-8 sm:flex-row">
            <Image
              width={144}
              height={144}
              className="mx-auto mb-4 w-36 h-36 rounded-full sm:ml-0 sm:mr-6"
              src={gravatar("roop@roopc.net", 200)}
              alt="Roopesh Avatar"
            />
            <div className="text-center sm:text-left">
              <h3 className="justify-center sm:justify-start text-xl font-bold tracking-tight text-gray-900 dark:text-white">
                Roopesh Chander
              </h3>
              <span className="text-gray-500 dark:text-gray-400">
                Technical Consultant
              </span>
              <p className="mt-3 mb-4 max-w-sm font-light text-gray-500 dark:text-gray-400">
                {/* TODO: bio */}
              </p>
              <ul className="flex justify-center space-x-4 sm:justify-start">
                <li>
                  <GitHubIcon url="https://github.com/roop" />
                </li>
              </ul>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
