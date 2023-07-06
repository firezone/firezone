import NewsletterSignup from "@/components/NewsletterSignup";

export default function Page() {
  return (
    <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
      <div className="mx-auto max-w-screen-md sm:text-center">
        <h2 className="justify-center mb-4 text-2xl font-extrabold tracking-tight text-neutral-900 sm:text-6xl dark:text-white">
          Firezone Newsletter
        </h2>
        <p className="mx-auto mb-8 max-w-2xl text-neutral-800 md:mb-12 sm:text-xl dark:text-neutral-100">
          Sign up with your email to receive roadmap updates, how-tos, and
          product announcements from the Firezone team.
        </p>
      </div>
      <NewsletterSignup />
    </div>
  );
}
