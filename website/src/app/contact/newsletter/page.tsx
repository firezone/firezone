import Image from "next/image";
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
        <NewsletterSignup />
      </div>
    </section>
  );
}
