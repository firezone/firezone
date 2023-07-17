import Link from "next/link";
import { HiChatBubbleLeftRight, HiUserGroup, HiStar } from "react-icons/hi2";

export default function JoinOurCommunity() {
  return (
    <section className="border-t border-neutral-200 py-24 bg-gradient-to-b from-neutral-100 to-primary-50">
      <div className="flex flex-col justify-center items-center">
        <h2 className="mb-4 text-4xl tracking-tight font-bold text-neutral-900 ">
          Join our community
        </h2>
        <p className="mx-2 my-4 text-xl max-w-screen-lg text-center text-primary-900 ">
          Participate in Firezone's development, suggest new features, and
          collaborate with other Firezone users.
        </p>
      </div>
      <div className="gap-4 items-center pt-4 px-4 mx-auto max-w-screen-lg lg:grid lg:grid-cols-3 xl:gap-8 sm:pt-8 lg:px-6 ">
        <div className="py-8 rounded-md shadow-md text-center bg-white">
          <HiUserGroup className="flex-shrink-0 w-12 h-12 mx-auto text-primary-450 " />
          <h3 className="text-4xl my-8 font-bold justify-center tracking-tight text-primary-900 ">
            30+
          </h3>
          <p className="mb-8 text-xl font-semibold">Contributors</p>
          <button
            type="button"
            className="inline-flex shadow-lg justify-center items-center py-3 px-5 text-base font-bold text-center text-white rounded-md hover:scale-105 duration-0 transform transition bg-gradient-to-br from-accent-700 to-accent-600"
          >
            <Link href="https://github.com/firezone/firezone/fork">
              Fork us on GitHub
            </Link>
          </button>
        </div>
        <div className="py-8 rounded-md shadow-md text-center bg-white">
          <HiStar className="flex-shrink-0 w-12 h-12 mx-auto text-primary-450 " />
          <h3 className="text-4xl my-8 font-bold justify-center tracking-tight text-primary-900 ">
            4,300+
          </h3>
          <p className="mb-8 text-xl font-semibold">GitHub stars</p>
          <button
            type="button"
            className="inline-flex shadow-lg justify-center items-center py-3 px-5 text-base font-bold text-center text-white rounded-md hover:scale-105 duration-0 transform transition bg-gradient-to-br from-accent-700 to-accent-600"
          >
            <Link href="https://github.com/firezone/firezone">
              Drop us a star
            </Link>
          </button>
        </div>
        <div className="py-8 rounded-md shadow-md text-center bg-white">
          <HiChatBubbleLeftRight className="flex-shrink-0 w-12 h-12 mx-auto text-primary-450 " />
          <h3 className="text-4xl my-8 font-bold justify-center tracking-tight text-primary-900 ">
            250+
          </h3>
          <p className="mb-8 text-xl font-semibold">Members</p>
          <button
            type="button"
            className="inline-flex shadow-lg justify-center items-center py-3 px-5 text-base font-bold text-center text-white rounded-md hover:scale-105 duration-0 transform transition bg-gradient-to-br from-accent-700 to-accent-600"
          >
            <Link href="https://firezone-users.slack.com/join/shared_invite/zt-19jd956j4-rWcCqiKMh~ikPGsUFbvZiA#/shared-invite/email">
              Join our Slack
            </Link>
          </button>
        </div>
      </div>
    </section>
  );
}
