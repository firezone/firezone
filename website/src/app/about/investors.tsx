import Link from "next/link";
import Image from "next/image";

export default function Investors() {
  return (
    <section className="border-t border-neutral-200 bg-neutral-100">
      <div className="py-8 px-4 mx-auto max-w-screen-xl lg:py-16 lg:px-6">
        <h2 className="mb-14 justify-center md:text-5xl text-4xl tracking-tight font-extrabold text-neutral-900 leading-none">
          INVESTORS
        </h2>
        <div className="pt-12 grid grid-cols-1 sm:grid-cols-2 md:grid-cols-6 gap-12">
          <div className="flex p-4">
            <Link className="my-auto" href={new URL("https://ycombinator.com")}>
              <Image
                src="/images/yc-logo-square.svg"
                alt="Y Combinator"
                width={75}
                height={75}
              />
            </Link>
          </div>
          <div className="flex">
            <div className="my-auto p-2 bg-neutral-900">
              <Link href={new URL("https://1984.vc")}>
                <Image
                  src="/images/1984-logo.svg"
                  alt="1984 Ventures"
                  width={50}
                  height={50}
                  className="mx-auto"
                />
              </Link>
            </div>
          </div>
          <div className="flex">
            <Link className="my-auto" href={new URL("https://uncorrelated.vc")}>
              <Image
                src="/images/uncorrelated-logo.png"
                alt="Uncorrelated Ventures"
                width={200}
                height={100}
              />
            </Link>
          </div>
          <div className="flex">
            <Link
              className="my-auto"
              href={new URL("https://helium-3ventures.com")}
            >
              <Image
                src="/images/helium3-logo.png"
                alt="Helium-3 Ventures"
                width={200}
                height={100}
              />
            </Link>
          </div>
          <div className="flex">
            <Link
              className="my-auto"
              href={new URL("https://aminocapital.com")}
            >
              <Image
                src="/images/amino-logo.png"
                alt="Amino Capital"
                width={200}
                height={100}
              />
            </Link>
          </div>
          <div className="flex">
            <Link className="my-auto" href={new URL("https://gaingels.com")}>
              <Image
                src="/images/gaingels-logo.png"
                alt="Gaingels"
                width={200}
                height={100}
              />
            </Link>
          </div>
        </div>
      </div>
    </section>
  );
}
