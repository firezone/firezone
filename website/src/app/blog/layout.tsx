import NewsletterSignup from "@/components/NewsletterSignup";
import Image from "next/image";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="pt-14 flex flex-col">
      <div className="bg-neutral-100 mx-auto w-screen text-center">
        <Image
          alt="Firezone logo"
          width={125}
          height={125}
          src="/images/logo-main.svg"
          className="py-12 mx-auto"
        />
      </div>
      {children}
      <div className="bg-neutral-50 py-8">
        <h2 className="justify-center mb-4 text-2xl font-extrabold tracking-tight text-neutral-900 sm:text-4xl">
          Firezone Newsletter
        </h2>
        <p className="mx-auto mb-8 text-center max-w-2xl text-neutral-900 md:mb-12 text-lg sm:text-xl">
          Sign up with your email to receive roadmap updates, how-tos, and
          product announcements from the Firezone team.
        </p>
        <NewsletterSignup />
      </div>
    </div>
  );
}
