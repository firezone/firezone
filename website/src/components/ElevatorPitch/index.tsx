"use client";

import Link from "next/link";
import Image from "next/image";
import { ReactNode } from "react";
import { manrope } from "@/lib/fonts";
import type { CustomFlowbiteTheme } from "flowbite-react";
import { HiMiniShieldCheck } from "react-icons/hi2";

interface OptionButtonProps {
  title: string;
  desc: string;
  icon?: ReactNode;
}

const OptionButton = ({ title, desc, icon }: OptionButtonProps) => {
  return (
    <button
      className={`flex border-b-[1px] border-neutral-200 py-5 gap-4 ${manrope.className}`}
    >
      {icon}
      <div>
        <p className="text-neutral-900 font-semibold text-lg text-left mb-1.5">
          {title}
        </p>
        <p className="text-slate-700 text-left text-md">{desc}</p>
      </div>
    </button>
  );
};

export default function ElevatorPitch() {
  return (
    <div className="flex flex-col max-w-[600px]">
      <h6 className="uppercase text-md font-semibold text-primary-450 tracking-wide mb-4">
        Stay Connected
      </h6>
      <div className="sm:mx-auto mb-4 text-4xl md:text-6xl text-pretty text-left ">
        <h3 className=" tracking-tight font-bold inline-block">
          Supercharge your workforce in{" "}
          <span className="text-primary-450">minutes</span>.
        </h3>
      </div>
      <div className="max-w-screen-md">
        <p
          className={`text-lg text-left text-pretty text-slate-700 ${manrope.className}`}
        >
          Protect your workforce without the tedious configuration.
        </p>
      </div>
      <div className="mt-16">
        <OptionButton
          title="Built on WireGuard®"
          desc="Control access to VPCs, subnets, hosts by IP or DNS, and even public
            SaaS apps."
          icon={<HiMiniShieldCheck size={32} className="text-primary-400" />}
        />
        <OptionButton
          title="Scales with your business."
          desc="Control access to VPCs, subnets, hosts by IP or DNS, and even public
            SaaS apps."
          icon={<HiMiniShieldCheck size={32} className="text-primary-400" />}
        />
        <OptionButton
          title="Zero attack surface."
          desc="Control access to VPCs, subnets, hosts by IP or DNS, and even public
            SaaS apps."
          icon={<HiMiniShieldCheck size={32} className="text-primary-400" />}
        />
        <OptionButton
          title="Open source for full transparency."
          desc="Control access to VPCs, subnets, hosts by IP or DNS, and even public
            SaaS apps."
          icon={<HiMiniShieldCheck size={32} className="text-primary-400" />}
        />
      </div>
    </div>
  );
}
