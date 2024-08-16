"use client";

import { useRef } from "react";
import Image from "next/image";
import Link from "next/link";
import { HiArrowLeft, HiArrowRight } from "react-icons/hi2";
import { FaHeart } from "react-icons/fa";
import { manrope } from "@/lib/fonts";

const customerData = [
  {
    desc: `When producing live broadcasts for Fortune 500 companies security is of
      the utmost importance. We therefore selected Firezone for its robust
      WireGuard-based architecture. The flexible policy system and simple &
      clean user experience make Firezone the best fitting product for us in
      the market after trying several other solutions like Tailscale, OpenVPN,
      and Nebula.`,
    authorName: "Robert Buisman",
    authorImage: "/images/portrait-robert-buisman.png",
    authorTitle: "CEO, NOMOBO",
  },
  {
    desc: `Firezone's easy-to-setup, sleek, and simple interface makes management
      effortless. It perfectly met our zero-trust security needs without the
      complexity found in other products we tested.`,
    authorName: "Mark Sim",
    authorImage: "/images/portrait-mark-sim.jpg",
    authorTitle: "Technical Account Manager, Beakon",
  },
  {
    desc: `After comparing Tailscale, we ultimately chose Firezone to secure access
      to our data warehouses. Firezone's ease of configuration and robust
      policy-based access system made it the clear choice for our needs.`,
    authorName: "James Winegar",
    authorImage: "/images/portrait-james-winegar.png",
    authorTitle: "CEO, Corrdyn",
  },
  {
    desc: `At Strong Compute, we have been using Firezone for over 3 years and it
      is still the most stable and best VPN solution we tested for remote access.`,
    authorName: "Cian Byrne",
    authorImage: "/images/portrait-cian-byrne.jpg",
    authorTitle: "Founding Engineer, Strong Compute",
  },
];

interface TestimonialBoxProps {
  desc: string;
  authorImage: string;
  authorName: string;
  authorTitle: string;
}

const TestimonialBox = ({
  desc,
  authorImage,
  authorName,
  authorTitle,
}: TestimonialBoxProps) => {
  return (
    <div className="first:sm:ml-48 last:sm:mr-48 shrink-0 px-8 md:px-12 py-8 md:py-12 bg-[#1B1B1D] snap-center flex flex-col rounded-2xl justify-between w-fit max-w-[540px] h-84">
      <p className="text-md md:text-lg tracking-wide font-light mb-2 md:mb-6 break-keep italic text-neutral-50">
        "{desc}"
      </p>
      <div className="flex gap-4 items-center">
        <Image
          src={authorImage}
          alt="author portrait"
          width={128}
          height={128}
          className="w-10 h-10 sm:h-12 sm:h-12 md:h-16 md:w-16 rounded-full"
        />
        <div>
          <p className="text-md md:text-lg text-neutral-50">{authorName}</p>
          <p className="text-sm md:text-md font-light text-neutral-50">
            {authorTitle}
          </p>
        </div>
      </div>
    </div>
  );
};

export default function CustomerTestimonials() {
  const scrollRef = useRef<HTMLDivElement>(null);

  const scrollLeft = () => {
    if (scrollRef.current) {
      scrollRef.current.scrollBy({
        left: -540,
        behavior: "smooth",
      });
    }
  };

  const scrollRight = () => {
    if (scrollRef.current) {
      scrollRef.current.scrollBy({
        left: 540,
        behavior: "smooth",
      });
    }
  };

  return (
    <section className="bg-neutral-950 py-24">
      <div className="relative mx-auto max-w-screen-lg">
        <div className="px-8 sm:px-16 md:px-24 mb-12 md:mb-16">
          <div>
            <h3
              className={`text-white text-3xl leading-5 md:text-4xl lg:text-5xl tracking-tight font-medium inline-block text-left mb-2 ${manrope.className}`}
            >
              Customers{" "}
              <FaHeart className="text-red-500 w-12 h-12 mx-1 inline-block" />{" "}
              us,
            </h3>
            <p className="text-neutral-500 text-2xl md:text-3xl font-medium">
              and we love them back.
            </p>
          </div>
        </div>

        <div
          ref={scrollRef}
          className="sm:fade-side flex gap-12 px-8 sm:px-0 w-full snap-x snap-mandatory pb-24 sm:pb-12 overflow-x-auto dark-scroll"
        >
          {customerData.map((item, index) => (
            <TestimonialBox
              key={index}
              authorTitle={item.authorTitle}
              desc={item.desc}
              authorImage={item.authorImage}
              authorName={item.authorName}
            />
          ))}
        </div>
        <div className="absolute bottom-12 left-1/2 -translate-x-1/2 sm:left-auto sm:translate-x-0 sm:bottom-auto sm:right-16 sm:top-8 flex items-center gap-16">
          <button onClick={scrollLeft}>
            <HiArrowLeft className="hover:bg-[#1b1b1d] cursor-pointer rounded-full border p-1.5 text-neutral-50 w-8 h-8" />
          </button>
          <button onClick={scrollRight}>
            <HiArrowRight className="hover:bg-[#1b1b1d] cursor-pointer rounded-full border p-1.5 text-neutral-50 w-8 h-8" />
          </button>
        </div>
      </div>
    </section>
  );
}
