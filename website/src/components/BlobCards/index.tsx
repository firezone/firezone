import Link from "next/link";
import Image from "next/image";
import { HiArrowLongRight, HiCheck, HiXMark } from "react-icons/hi2";
import { manrope } from "@/lib/fonts";

export default function BlobCards() {
  return (
    <div className="max-w-screen-xl flex flex-col items-center mx-auto">
      <h3
        className={` text-3xl md:text-4xl lg:text-5xl leading-none tracking-tight font-bold text-balance text-center my-2 lg:max-w-[70%] ${manrope.className}`}
      >
        Protect your workforce without the tedious configuration.
      </h3>
      <div className="flex justify-center w-full gap-6 mt-8">
        <div className="relative flex justify-center bg-primary-200 rounded-3xl h-[480px] w-7/12 p-8 overflow-hidden max-w-[675px]">
          <div className="">
            <h4
              className={`font-semibold tracking-tight leading-none text-xl mb-3 ${manrope.className}`}
            >
              Achieve compliance without the headache.
            </h4>
            <p>
              Firezone's advanced Policy Engine logs can be configured to allow
              access only from certain countries, IPs, and timeframes, so you
              can easily demonstrate compliance with internal and external
              security audits.
            </p>
            <Link href="/kb/architecture">
              <button className="group transform transition duration-50 hover:ring-1 hover:ring-neutral-900 inline-flex mt-6 gap-1 items-center bg-neutral-900 rounded-full text-neutral-50 text-sm px-5 py-2.5">
                Read about Firezone's architecture
                <HiArrowLongRight
                  className="group-hover:translate-x-1 group-hover:scale-110 duration-100 transform
    transition"
                />
              </button>
            </Link>
          </div>
          <Image
            className="absolute bottom-0 translate-y-12 self-center"
            src="/images/compliance-dashboard.svg"
            width={600}
            height={289}
            alt="Policy Dashboard"
          />
        </div>
        <div className="relative flex justify-center items-end bg-accent-200 rounded-3xl h-[480px] w-5/12 p-8 overflow-hidden max-w-[675px]">
          <div className="flex flex-col items-center text-center max-w-[420px] text-pretty">
            <h4
              className={`font-semibold tracking-tight leading-none text-xl mb-3 ${manrope.className}`}
            >
              Add two-factor auth to WireGuard.
            </h4>
            <p>
              Looking for 2FA for WireGuard? Look no further. Firezone
              integrates with any OIDC-compatible identity provider to
              consistently enforce multi-factor authentication across your
              workforce.
            </p>
            <Link href="/kb/authenticate">
              <button className="group transform transition duration-50 hover:ring-1 hover:ring-neutral-900 inline-flex mt-6 gap-1 items-center bg-neutral-900 rounded-full text-neutral-50 text-sm px-5 py-2.5">
                Connect your identity provider
                <HiArrowLongRight
                  className="group-hover:translate-x-1 group-hover:scale-110 duration-100 transform
    transition"
                />
              </button>
            </Link>
          </div>
          <Image
            className="absolute top-5 self-center"
            src="/images/two-factor-graphic.svg"
            width={260}
            height={289}
            alt="Two-Factor Graphic"
          />
        </div>
      </div>
    </div>
  );
}
