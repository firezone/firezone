import Image from "next/image";

export default function CustomerLogos() {
  return (
    <>
      <div className="flex justify-center items-center p-8 mt-8">
        <h3 className="text-2xl tracking-tight font-bold text-neutral-800 ">
          Trusted by organizations like
        </h3>
      </div>
      <div className="gap-8 max-w-screen-xl grid justify-items-center sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-6 px-16 py-8">
        <Image
          alt="bunq logo"
          src="/images/bunq-logo.png"
          width={100}
          height={55}
        />
        <Image
          alt="tribe logo"
          src="/images/tribe-logo.png"
          width={100}
          height={55}
        />
        <Image
          alt="wolfram logo"
          src="/images/wolfram-logo.png"
          width={100}
          height={55}
        />
        <Image
          alt="rebank logo"
          src="/images/rebank-logo.png"
          width={100}
          height={55}
        />
        <Image
          alt="square1 logo"
          src="/images/square1-logo.png"
          width={100}
          height={55}
        />
        <Image
          alt="db11 logo"
          src="/images/db11-logo.png"
          width={100}
          height={55}
        />
      </div>
    </>
  );
}
