import NewsletterSignup from "@/components/NewsletterSignup";
import Image from "next/image";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="pt-14 flex flex-col">
      <div className="bg-neutral-900 mx-auto w-screen text-center">
        <Image
          alt="Firezone logo light"
          width={147}
          height={92}
          src="/images/logo-main-light-primary.svg"
          className="py-12 mx-auto"
        />
      </div>
      <div className="bg-neutral-50 border-b border-neutral-100">
        <div className="py-8 px-4 sm:py-10 sm:px-6 md:py-12 md:px-8 lg:py-14 lg:px-10 mx-auto max-w-screen-lg w-full">
          <h1 className="text-4xl sm:text-5xl md:text-6xl lg:text-7xl xl:text-8xl font-bold tracking-tight">
            Blog
          </h1>
          <p className="text-md sm:text-lg md:text-xl lg:text-2xl mt-4 md:mt-6 lg:mt-8 tracking-tight">
            Announcements, how-tos, and more from the Firezone team.
          </p>
        </div>
      </div>
      {children}
      <div className="bg-neutral-50 w-screen">
        <div className="px-4 py-8 max-w-md md:max-w-screen-lg mx-auto">
          <h2 className="justify-center mb-4 text-2xl font-extrabold tracking-tight sm:text-4xl">
            Firezone Newsletter
          </h2>
          <p className="mx-auto mb-8 text-center max-w-2xl md:mb-12 text-lg sm:text-xl">
            Sign up with your email to receive roadmap updates, how-tos, and
            product announcements from the Firezone team.
          </p>
          <NewsletterSignup />
        </div>
      </div>
    </div>
  );
}
