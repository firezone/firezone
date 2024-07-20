import { HiArrowLongRight } from "react-icons/hi2";
import Button from "@/components/Button";

export default function Hero() {
  return (
    <section className="bg-neutral-950 h-[800px] px-5 pt-24">
      <div className="flex flex-col items-center py-16 gap-6 mx-auto max-w-screen-md text-center">
        <h1 className="font-manrope inline tracking-tight font-medium bg-gradient-to-b from-white from-70% to-slate-400 text-transparent bg-clip-text text-6xl sm:text-6xl md:text-7xl">
          Upgrade your workforce with zero trust
        </h1>
        <p className="w-5/6 font-manrope text-lg font-medium text-neutral-500">
          Protect your remote workforce without the tedious configuration.
          Firezone is a fast, flexible VPN replacement built for the modern
          workforce.
        </p>
        <span className="flex text-white font-manrope space-x-4 mt-8">
          <button className=" flex px-8 py-3.5 font-normal items-center gap-1 rounded-lg">
            Get started for free
            <HiArrowLongRight
              className={
                "group-hover:translate-x-1 group-hover:scale-110 duration-100 transform transition "
              }
            />
          </button>
          <button className="font-bold flex px-8 py-3.5 items-center gap-1 bg-primary-450 rounded-lg">
            Book a demo
            <HiArrowLongRight
              className={
                "group-hover:translate-x-1 group-hover:scale-110 duration-100 transform transition "
              }
            />
          </button>
        </span>
      </div>
    </section>
  );
}
