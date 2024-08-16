"use client";

import { ReactNode, useState } from "react";
import {
  HiMiniShieldCheck,
  HiMiniPresentationChartLine,
} from "react-icons/hi2";
import { HiLightningBolt } from "react-icons/hi";
import { FaBookOpen } from "react-icons/fa";
import { manrope } from "@/lib/fonts";
import Image from "next/image";

export default function ElevatorPitch() {
  const [selectedOption, setSelectedOption] = useState(5);

  const data = [
    {
      title: "Fast and lightweight.",
      desc: "Built on WireGuard® to be 3-4x faster than OpenVPN.",
      icon: <HiLightningBolt className="min-w-8 h-8 text-primary-400" />,
    },
    {
      title: "Scales with your business.",
      desc: "Automatic load balancing and failover with two or more Gateways.",
      icon: (
        <HiMiniPresentationChartLine className="min-w-8 h-8 text-primary-400" />
      ),
    },
    {
      title: "Minimize your attack surface.",
      desc: "Firezone's hole-punching tech hides your resources from the internet.",
      icon: <HiMiniShieldCheck className="min-w-8 h-8 text-primary-400" />,
    },
    {
      title: "Open source for full transparency.",
      desc: "Our entire product is open-source, allowing anyone to audit the codebase.",
      icon: <FaBookOpen className="min-w-8 h-8 text-primary-400" />,
    },
  ];

  interface OptionButtonProps {
    title: string;
    desc: string;
    icon: ReactNode;
    index: number;
  }

  const OptionButton = ({ title, desc, icon, index }: OptionButtonProps) => {
    return (
      <button
        className={`flex flex-col lg:flex-row lg:w-full pointer-events-none
          items-start lg:items-center py-6 lg:py-0 gap-4 border-[1px] justify-center
          lg:justify-start transition duration-200 ease-in-out
        ${
          selectedOption == index
            ? "bg-primary-50 border-primary-450"
            : "bg-transparent border-transparent hover:bg-primary-50 hover:border-primary-200"
        }`}
        onClick={() => setSelectedOption(index)}
      >
        {icon}
        <div>
          <p className="text-neutral-900 font-semibold text-lg text-left mb-0.5">
            {title}
          </p>
          <p className="text-neutral-800 text-left text-md mr-4">{desc}</p>
        </div>
      </button>
    );
  };

  return (
    <div className="flex w-full h-fit lg:flex-row flex-col justify-center gap-6 lg:gap-12 xl:gap-20 items-center max-w-screen-xl ">
      <div className="flex flex-col w-full h-full justify-between lg:w-[480px] xl:w-[580px]">
        <div>
          <h6 className="uppercase text-sm font-semibold text-primary-450 tracking-wide mb-2">
            Stay Connected
          </h6>
          <div className="mb-2 text-3xl md:text-4xl lg:text-5xl ">
            <h3
              className={`leading-tight text-pretty text-left tracking-tight font-bold inline-block ${manrope.className}`}
            >
              Supercharge your workforce
              <span className="text-primary-450"> in minutes.</span>
            </h3>
          </div>
          <div className="max-w-screen-md">
            <p className={`text-lg text-left text-pretty text-neutral-800 `}>
              Firezone secures apps, services, networks and everything in
              between.
            </p>
            <p className="text-lg font-semibold text-left text-pretty text-neutral-800">
              No ACL hell required.
            </p>
          </div>
        </div>

        <div className="lg:flex grid  grid-cols-1 sm:grid-cols-2 lg:flex-col my-8 lg:mt-16 lg:space-y-8">
          {data.map((item, index) => (
            <OptionButton
              key={index}
              title={item.title}
              desc={item.desc}
              icon={item.icon}
              index={index}
            />
          ))}
        </div>
      </div>
      <div className="w-full h-auto lg:max-w-[600px] overflow-hidden flex justify-center items-center rounded-xl lg:h-[600px] lg:w-[40%] bg-gradient-to-b from-[#FFF5ED] to-[#F2EEFE]">
        <Image
          src="/images/simple-demonstration.png"
          className="max-w-[600px] w-full lg:max-h-[400px] lg:object-cover rounded-lg"
          width={600}
          height={400}
          alt="Elevator pitch graphic"
        />
      </div>
    </div>
  );
}
