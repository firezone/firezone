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
      {children}
    </div>
  );
}
