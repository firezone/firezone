import Link from "next/link";
import Image from "next/image";
import { HiArrowLongRight, HiCheck, HiXMark } from "react-icons/hi2";

export default function BattleCard2() {
  return (
    <section className="bg-white px-4 sm:px-8 md:px-16 py-16">
      <div className="sm:mx-auto px-4 flex flex-col items-center">
        <h6 className="uppercase text-sm font-semibold text-primary-450 tracking-wide ">
          Compare
        </h6>
        <h3 className="text-3xl md:text-4xl lg:text-5xl tracking-tight font-bold inline-block text-center my-2">
          More features
          <span className="text-primary-450"> for less</span>
        </h3>
        <p
          className={`text-lg text-center text-pretty text-neutral-800 mt-2 mb-16 `}
        >
          See how Firezone stacks up against the competition.
        </p>

        <div className="max-w-screen-lg w-full px-0 sm:px-4">
          <div className="flex w-full items-end justify-start lg:justify-center overflow-x-auto shrink-0">
            <ul
              role="list"
              className="text-sm md:text-base min-w-[180px] md:min-w-[300px]"
            >
              <li className="px-6 h-14 place-content-center bg-neutral-100">
                Automatic NAT64 and NAT46
              </li>
              <li className="px-6 h-14 place-content-center w-full">
                Open source
              </li>
              <li className="px-6 h-14 place-content-center w-full bg-neutral-100">
                Built on WireGuard®
              </li>
              <li className="px-6 h-14 place-content-center w-full">
                IPv6 support
              </li>
              <li className="px-6 h-14 place-content-center w-full bg-neutral-100">
                DNS-based routing
              </li>
              <li className="h-20" />
            </ul>
            <ul
              role="list"
              className={`flex flex-col items-center border border-primary-450 bg-primary-100 rounded-xl  min-w-[200px]`}
            >
              <li className="h-[72px] flex justify-center items-center px-6 ">
                <Image
                  width={150}
                  height={150}
                  src={"/images/logo-text-light.svg"}
                  alt="Firezone Logo"
                  className="flex w-32 sm:w-40 ml-2 mr-2 sm:mr-5"
                />
              </li>
              <li className="h-14 flex justify-center items-center w-full ">
                <HiCheck className="text-2xl text-green-600" />
              </li>
              <li className="h-14 flex justify-center items-center w-full ">
                <HiCheck className="text-2xl text-green-600" />
              </li>
              <li className="h-14 flex justify-center items-center w-full ">
                <HiCheck className="text-2xl text-green-600" />
              </li>
              <li className="h-14 flex justify-center items-center w-full ">
                <HiCheck className="text-2xl text-green-600" />
              </li>
              <li className="h-14 flex justify-center items-center w-full ">
                <HiCheck className="text-2xl text-green-600" />
              </li>
              <li className="py-3 h-20 ">
                <button
                  type="button"
                  className="bg-accent-450 text-nowrap rounded-lg group lg:text-lg text-md inline-flex justify-center items-center lg:py-3 py-2 px-5 font-semibold text-center text-white hover:ring-1 hover:ring-accent-500 duration-50 transform transition"
                >
                  <Link href="/contact/sales">Book a demo</Link>
                  <HiArrowLongRight className="group-hover:translate-x-1 transition duration-50 group-hover:scale-110 transform ml-2 -mr-1 w-7 h-7" />
                </button>
              </li>
            </ul>
            <ul
              role="list"
              className={`flex flex-col items-center mb-px  min-w-[160px] md:min-w-[200px]`}
            >
              <li className="h-[72px] px-8 flex justify-center items-center font-bold tracking-tight text-slate-600">
                Tailscale
              </li>
              <li className="h-14 flex justify-center items-center w-full bg-neutral-100">
                <HiXMark className="text-2xl text-red-600" />
              </li>
              <li className="h-14 flex justify-center items-center w-full ">
                Partial
              </li>
              <li className="h-14 flex justify-center items-center w-full bg-neutral-100">
                <HiCheck className="text-2xl text-green-600" />
              </li>
              <li className="h-14 flex justify-center items-center w-full">
                <HiCheck className="text-2xl text-green-600" />
              </li>
              <li className="h-14 flex justify-center items-center w-full bg-neutral-100">
                Partial
              </li>
              <li className="h-20" />
            </ul>
            <ul
              role="list"
              className={`flex flex-col items-center mb-px min-w-[160px] md:min-w-[200px]`}
            >
              <li className="h-[72px] px-8 flex justify-center items-center font-bold tracking-tight text-slate-600">
                Twingate
              </li>
              <li className="h-14 flex justify-center items-center w-full bg-neutral-100">
                <HiXMark className="text-2xl text-red-600" />
              </li>
              <li className="h-14 flex justify-center items-center w-full ">
                <HiXMark className="text-2xl text-red-600" />
              </li>
              <li className="h-14 flex justify-center items-center w-full bg-neutral-100">
                <HiXMark className="text-2xl text-red-600" />
              </li>
              <li className="h-14 flex justify-center items-center w-full">
                <HiXMark className="text-2xl text-red-600" />
              </li>
              <li className="h-14 flex justify-center items-center w-full bg-neutral-100">
                <HiCheck className="text-2xl text-green-600" />
              </li>
              <li className="h-20" />
            </ul>
          </div>
          <p className="text-neutral-900 text-center text-xs my-4">
            <i>Last updated: 07/14/2024</i>
          </p>
        </div>
      </div>
    </section>
  );
}
