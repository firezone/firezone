"use client";

import { ReactNode, useState } from "react";
import { HiCloud, HiMiniPuzzlePiece, HiLockClosed } from "react-icons/hi2";
import { SlideIn } from "@/components/Animations";
import { manrope } from "@/lib/fonts";
import ActionLink from "../ActionLink";
import UpgradeDiagram from "../Animations/UpgradeDiagram";

export default function FeatureCards() {
  return (
    <div className="flex w-full justify-center">
      <div className="flex flex-col items-center mx-auto">
        <div className="flex mb-8 lg:flex-row flex-col w-full items-start lg:items-end justify-between">
          <div className="">
            <h6 className="uppercase text-sm font-semibold text-primary-450 tracking-wide mb-2 lg:mb-4">
              built for you
            </h6>
            <div className="mb-4 lg:mb-0 text-3xl md:text-4xl lg:text-5xl w-[460px] lg:w-[600px]">
              <h3
                className={` text-pretty text-left leading-tight tracking-tight font-bold inline-block ${manrope.className}`}
              >
                Simplify access management
                <span className="text-primary-450"> with WireGuard.</span>
              </h3>
            </div>
          </div>
          <div className="">
            <p
              className={`text-lg mb-6 text-left text-pretty text-neutral-800 w-[400px] `}
            >
              Seamlessly manage thousands of lightweight tunnels to whatever
              resources you need, whenever.
            </p>
            <ActionLink href="/kb/deploy/resources">
              Protect your resources
            </ActionLink>
          </div>
        </div>
        {/* <div className="relative w-[80%]">
          <div className="absolute left-1/2 -translate-x-1/2 translate-y-1/2 blur-[120px] bg-primary-400 rounded-full w-[220px] h-[220px]" />
          <UpgradeDiagram />
        </div> */}

        <div className="mt-8 items-stretch mx-auto gap-4 md:max-w-screen-lg grid md:grid-cols-3">
          <SlideIn
            direction="left"
            delay={0.5}
            duration={1}
            className="flex flex-col p-5 md:p-8 border-[1px] rounded-xl border-neutral-300"
          >
            <div className="h-12 w-12 md:h-14 md:w-14 flex rounded-xl bg-[#FFE9EB] justify-center items-center mb-7">
              <HiCloud color="#EF7E88" className="w-6 h-6 lg:w-7 lg:h-7" />
            </div>
            <h4
              className={`text-md md:text-lg tracking-tight text-neutral-900 font-semibold mb-1 ${manrope.className}`}
            >
              Flexible
            </h4>
            <p className={`text-sm md:text-md semi-bold text-neutral-800`}>
              Control access to VPCs, subnets, hosts by IP or DNS, and even
              public SaaS apps.
            </p>
          </SlideIn>
          <SlideIn
            direction="left"
            delay={0.75}
            duration={1}
            className="flex flex-col p-6 md:p-8 border-[1px] rounded-xl border-neutral-300"
          >
            <div className="h-12 w-12 md:h-14 md:w-14 flex rounded-xl bg-[#E3F5FF] justify-center items-center mb-7">
              <HiLockClosed color="#719CF1" className="w-6 h-6 lg:w-7 lg:h-7" />
            </div>
            <h4
              className={`text-md md:text-lg tracking-tight text-neutral-900 font-semibold mb-1 ${manrope.className}`}
            >
              Secure
            </h4>
            <p className={`text-sm md:text-md semi-bold text-neutral-800`}>
              Users and groups automatically sync with your identity provider,
              so access is revoked immediately.
            </p>
          </SlideIn>
          <SlideIn
            direction="left"
            delay={1}
            duration={1}
            className="flex flex-col p-6 md:p-8 border-[1px] rounded-xl border-neutral-300"
          >
            <div className="h-12 w-12 md:h-14 md:w-14 flex rounded-xl bg-[#EFEAFF] justify-center items-center mb-7">
              <HiMiniPuzzlePiece
                color="#B195FE"
                className="w-6 h-6 lg:w-7 lg:h-7"
              />
            </div>
            <h4
              className={`text-md md:text-lg tracking-tight text-neutral-900 font-semibold mb-1 ${manrope.className}`}
            >
              Granular
            </h4>
            <p className={`text-sm md:text-md semi-bold text-neutral-800`}>
              Restrict access even further with port-level rules that control
              access to services, even on the same host.
            </p>
          </SlideIn>
        </div>
      </div>
    </div>
  );
}
