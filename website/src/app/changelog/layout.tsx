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
        <div className="py-8 px-4 sm:py-10 sm:px-6 md:py-12 md:px-8 lg:py-14 lg:px-10 mx-auto max-w-screen-lg w-full">
          <h1 className="text-4xl sm:text-5xl md:text-6xl lg:text-7xl xl:text-8xl font-bold tracking-tight">
            Changelog
          </h1>
          <p className="text-md sm:text-lg md:text-xl lg:text-2xl mt-4 md:mt-6 lg:mt-8 tracking-tight">
            A list of the most recent updates to Firezone, organized by
            component.
          </p>
        </div>
      </div>
      <div className="py-4 px-4 sm:py-6 sm:px-6 md:py-8 md:px-8 lg:py-10 lg:px-10 mx-auto max-w-screen-lg w-full">
        {children}
      </div>
    </div>
  );
}
