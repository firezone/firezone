import NewsletterSignup from "@/components/NewsletterSignup";

export default function Page() {
  return (
    <div className="bg-neutral-100 ">
      <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
        <div className="mx-auto max-w-screen-md sm:text-center">
          <h1 className="justify-center mb-4 text-2xl font-extrabold tracking-tight text-neutral-900 sm:text-6xl">
            Firezone Newsletter
          </h1>
          <p className="mx-auto mb-8 max-w-2xl text-neutral-900 md:mb-12 text-lg sm:text-xl">
            Sign up with your email to receive roadmap updates, how-to guides,
            and product announcements from the Firezone team.
          </p>
        </div>
        <NewsletterSignup />
      </div>
    </div>
  );
}
