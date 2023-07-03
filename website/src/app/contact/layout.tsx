import Image from "next/image";
export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="pt-14 flex flex-col">
      <section className="bg-neutral-50 dark:bg-neutral-900">
        <div className="bg-accent-400 mx-auto w-screen text-center">
          <Image
            alt="Firezone logo"
            width={250}
            height={250}
            src="/images/logo-main.svg"
            className="py-12 mx-auto"
          />
        </div>
        <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
          {children}
        </div>
      </section>
    </div>
  );
}
