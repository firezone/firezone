"use client";

import Link from "next/link";
import Image from "next/image";
import { ReactNode, useState } from "react";
import { manrope } from "@/lib/fonts";
import type { CustomFlowbiteTheme } from "flowbite-react";
import {
  HiMiniShieldCheck,
  HiMiniPresentationChartLine,
} from "react-icons/hi2";
import { HiLightningBolt, HiGlobe } from "react-icons/hi";

export default function ElevatorPitch() {
  const [selectedOption, setSelectedOption] = useState(5);

  const data = [
    {
      title: "Built on WireGuard®",
      desc: "Control access to VPCs, subnets, hosts by IP or DNS, and public SaaS apps.",
      icon: <HiLightningBolt className="min-w-8 h-8 text-primary-400" />,
    },
    {
      title: "Scales with your business.",
      desc: "Deploy two or more gateways for automatic load balancing and failover.",
      icon: (
        <HiMiniPresentationChartLine className="min-w-8 h-8 text-primary-400" />
      ),
    },
    {
      title: "Zero attack surface.",
      desc: "Firezone's holepunching tech establishes tunnels on-the-fly at the time of access.",
      icon: <HiMiniShieldCheck className="min-w-8 h-8 text-primary-400" />,
    },
    {
      title: "Open source for full transparency.",
      desc: "Our entire product is open-source, allowing anyone to audit the codebase.",
      icon: <HiGlobe className="min-w-8 h-8 text-primary-400" />,
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
        className={`flex flex-col lg:flex-row lg:w-full pointer-events-none rounded-xl items-start lg:items-center p-5 gap-4 border-[1px] justify-center lg:justify-start transition duration-200 ease-in-out ${
          manrope.className
        } ${
          selectedOption == index
            ? "bg-primary-50 border-primary-450"
            : "bg-transparent border-transparent hover:bg-primary-50 hover:border-primary-200"
        }`}
        onClick={() => setSelectedOption(index)}
      >
        {icon}
        <div>
          <p className="text-neutral-900 font-semibold text-md text-left mb-1.5">
            {title}
          </p>
          <p className="text-slate-700 text-left text-sm">{desc}</p>
        </div>
      </button>
    );
  };

  return (
    <div className="flex flex-col w-full lg:w-[480px] xl:w-[580px]">
      <h6 className="uppercase text-sm font-semibold text-primary-450 tracking-wide mb-2 lg:mb-4">
        Stay Connected
      </h6>
      <div className="mb-2 lg:mb-4 text-3xl md:text-4xl lg:text-5xl ">
        <h3 className=" text-pretty text-left tracking-tight font-bold inline-block">
          Supercharge your workforce
          <span className="text-primary-450"> in minutes.</span>
        </h3>
      </div>
      <div className="max-w-screen-md">
        <p
          className={`text-md text-left text-pretty text-slate-700 ${manrope.className}`}
        >
          Protect your workforce without the tedious configuration.
        </p>
      </div>
      <div className="lg:flex grid  grid-cols-1 sm:grid-cols-2 lg:flex-col mt-8 space-y-2">
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
  );
}
