import NewsletterSignup from "@/components/NewsletterSignup";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Newsletter Signup • Firezone",
  description:
    "Sign up to receive roadmap updates, how-to guides, and product announcements from the Firezone team.",
};

export default function Page() {
  return (
    <div className="bg-neutral-100">
      <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
        <div className="mx-auto max-w-screen-md sm:text-center">
          <h1 className="justify-center mb-4 text-5xl font-extrabold text-center leading-none tracking-tight text-neutral-900 sm:text-6xl">
            Firezone Newsletter
          </h1>
          <h2 className="mx-auto mb-8 max-w-2xl tracking-tight text-center text-neutral-800 md:mb-12 text-xl">
            Sign up with your email to receive roadmap updates, how-to guides,
            and product announcements from the Firezone team.
          </h2>
        </div>
        <NewsletterSignup />
      </div>
    </div>
  );
}
