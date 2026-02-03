import Image from "next/image";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="pt-14 flex flex-col">
      <div className="bg-neutral-950 mx-auto w-screen text-center">
        <Image
          alt="Firezone logo light"
          width={147}
          height={92}
          src="/images/logo-main-light-primary.svg"
          className="py-12 mx-auto"
        />
      </div>
      <div className="bg-neutral-50 border-b border-neutral-100">
        <div className="py-8 px-4 sm:py-12 sm:px-6 md:py-16 md:px-8 lg:py-20 lg:px-10 mx-auto max-w-screen-lg w-full">
          <h1
            className={`justify-center text-5xl sm:text-6xl md:text-7xl font-bold tracking-tight`}
          >
            Support
          </h1>
          <p className="text-center text-md md:text-lg lg:text-xl mt-2 md:mt-4 tracking-tight">
            {"Need help? We've got you covered. See our support options below."}
          </p>
        </div>
      </div>
      <div className="py-4 px-4 sm:py-6 sm:px-6 md:py-8 md:px-8 lg:py-10 lg:px-10 mx-auto max-w-screen-lg w-full">
        {children}
      </div>
    </div>
  );
}
