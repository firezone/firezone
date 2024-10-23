import { Metadata } from "next";
import NewsletterSignup from "@/components/NewsletterSignup";
import Posts from "./posts";

export const metadata: Metadata = {
  title: "Blog • Firezone",
  description: "Announcements, insights, and more from the Firezone team.",
};

export default function Page() {
  return (
    <section>
      <div className="bg-neutral-50 border-b border-neutral-100">
        <div className="py-8 px-4 sm:py-12 sm:px-6 md:py-16 md:px-8 lg:py-20 lg:px-10 mx-auto max-w-screen-lg w-full">
          <h1 className="justify-center text-5xl sm:text-6xl md:text-7xl font-bold tracking-tight">
            Blog
          </h1>
          <p className="text-center text-md md:text-lg lg:text-xl mt-2 md:mt-4 tracking-tight">
            Announcements, how-tos, and more from the Firezone team.
          </p>
        </div>
      </div>
      <Posts />
    </section>
  );
}
