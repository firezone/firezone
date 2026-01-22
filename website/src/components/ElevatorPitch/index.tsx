"use client";

import { ReactNode, useState } from "react";
import {
  HiMiniShieldCheck,
  HiMiniPresentationChartLine,
} from "react-icons/hi2";
import { HiLightningBolt } from "react-icons/hi";
import { FaBookOpen } from "react-icons/fa";
import Image from "next/image";
import { SlideIn } from "@/components/Animations";

export default function ElevatorPitch() {
  const [selectedOption, setSelectedOption] = useState(5);

  const data = [
    {
      title: "Fast and lightweight.",
      desc: "Built on WireGuard® to be 3-4x faster than OpenVPN.",
      icon: <HiLightningBolt className="min-w-8 h-8 text-primary-400" />,
      delay: 0.25,
    },
    {
      title: "Scales with your business.",
      desc: "Automatic load balancing and failover with two or more Gateways.",
      icon: (
        <HiMiniPresentationChartLine className="min-w-8 h-8 text-primary-400" />
      ),
      delay: 0.5,
    },
    {
      title: "Minimize your attack surface.",
      desc: "Firezone's hole-punching tech hides your resources from the internet.",
      icon: <HiMiniShieldCheck className="min-w-8 h-8 text-primary-400" />,
      delay: 0.75,
    },
    {
      title: "Open source for full transparency.",
      desc: "Our entire product is open-source, allowing anyone to audit the codebase.",
      icon: <FaBookOpen className="min-w-8 h-8 text-primary-400" />,
      delay: 1,
    },
  ];

  interface OptionButtonProps {
    title: string;
    desc: string;
    icon: ReactNode;
    index: number;
    delay: number;
  }

  const OptionButton = ({
    title,
    desc,
    icon,
    index,
    delay,
  }: OptionButtonProps) => {
    return (
      <SlideIn direction="left" delay={delay} duration={0.5}>
        <button
          className={`flex flex-col lg:flex-row lg:w-full pointer-events-none
          items-start lg:items-center py-6 lg:py-0 gap-4 border justify-center
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
      </SlideIn>
    );
  };

  return (
    <section className="px-4 sm:px-8 md:px-16 py-16">
      <div className="flex justify-center">
        <div className="flex w-full h-fit lg:flex-row flex-col justify-center gap-6 lg:gap-12 xl:gap-20 items-center max-w-screen-xl ">
          <div className="flex flex-col w-full h-full justify-between lg:w-[480px] xl:w-[580px]">
            <div>
              <h6 className="uppercase text-sm font-semibold text-primary-450 tracking-wide mb-2">
                Stay Connected
              </h6>
              <h3 className="mb-4 text-3xl md:text-4xl lg:text-5xl leading-tight tracking-tight font-bold inline-block">
                <span className="text-primary-450">Eliminate </span>
                ACL hell
              </h3>
              <p className="text-lg text-pretty text-neutral-800">
                Firezone secures apps, services, and networks with simple access
                policies that are manageable by mere humans.
              </p>
            </div>

            <div className="lg:flex grid  grid-cols-1 sm:grid-cols-2 lg:flex-col my-8 lg:mt-16 lg:space-y-8">
              {data.map((item, index) => (
                <OptionButton
                  key={index}
                  title={item.title}
                  desc={item.desc}
                  icon={item.icon}
                  index={index}
                  delay={item.delay}
                />
              ))}
            </div>
          </div>
          <div className="lg:max-w-1/2">
            <Image
              src="/images/elevator-pitch.png"
              width={500}
              height={500}
              alt="Elevator pitch graphic"
              className="mx-auto"
            />
          </div>
        </div>
      </div>
    </section>
  );
}
