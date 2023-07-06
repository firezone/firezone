import NewsletterSignup from "@/components/NewsletterSignup";
import Image from "next/image";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="pt-14 flex flex-col">
      <div className="bg-neutral-50 mx-auto w-screen text-center">
        <Image
          alt="Firezone logo"
          width={125}
          height={125}
          src="/images/logo-main.svg"
          className="py-12 mx-auto"
        />
      </div>
      {children}
      <div className="bg-neutral-50 dark:bg-neutral-800 pt-8">
        <NewsletterSignup />
      </div>
    </div>
  );
}
