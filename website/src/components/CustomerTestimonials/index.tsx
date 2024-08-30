"use client";

import { useRef } from "react";
import Image from "next/image";
import Link from "next/link";
import { HiArrowLeft, HiArrowRight } from "react-icons/hi2";
import { FaHeart } from "react-icons/fa";
import { manrope } from "@/lib/fonts";
import ActionLink from "../ActionLink";

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
  fontSize: string;
}

const TestimonialBox = ({
  desc,
  authorImage,
  authorName,
  authorTitle,
  fontSize,
}: TestimonialBoxProps) => {
  return (
    <div className="shrink-0 p-8 bg-[#1B1B1D] flex flex-col rounded-2xl justify-between w-fit lg:max-w-[320px] lg:min-h-[320px] h-fit">
      <p
        className={`absolute text-[140px] -translate-y-1/3 -z-1 text-white/15 font-semibold ${manrope.className}`}
      >
        "
      </p>
      <p
        className={`text-md  ${fontSize === "md" ? "lg:text-md" : "lg:text-lg"}
        } tracking-wide font-light mb-6 break-keep italic text-neutral-50 z-10`}
      >
        "{desc}"
      </p>
      <div className="flex gap-4 customerData[1]s-center">
        <Image
          src={authorImage}
          alt="author portrait"
          width={60}
          height={60}
          className="w-10 h-10 sm:h-12 md:h-12 md:w-12 rounded-full"
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
  // const scrollRef = useRef<HTMLDivElement>(null);

  // const scrollLeft = () => {
  //   if (scrollRef.current) {
  //     scrollRef.current.scrollBy({
  //       left: -540,
  //       behavior: "smooth",
  //     });
  //   }
  // };

  // const scrollRight = () => {
  //   if (scrollRef.current) {
  //     scrollRef.current.scrollBy({
  //       left: 540,
  //       behavior: "smooth",
  //     });
  //   }
  // };

  return (
    <section className="bg-neutral-950 py-24">
      <div className="relative flex flex-col lg:flex-row items-start lg:items-center justify-center max-w-screen-2xl">
        <div className="px-4 sm:px-16 lg:px-10 xl:px-16 mb-12 md:mb-16">
          <div>
            <h3
              className={`text-white text-3xl md:text-4xl leading-5 xl:text-5xl tracking-tight font-medium inline-block text-wrap sm:text-nowrap text-left ${manrope.className}`}
            >
              Customers{" "}
              <FaHeart className="text-red-500 w-12 h-12 mx-1 inline-block" />{" "}
              us,
            </h3>
            <h3 className="text-primary-450 text-3xl md:text-4xl leading-12 xl:text-5xl text-wrap sm:text-nowrap tracking-tight font-medium mb-6">
              and we love them back.
            </h3>
            <ActionLink href="/contact/sales" color="white">
              Book a demo
            </ActionLink>
          </div>
        </div>
        <div className="flex flex-col items-center px-4 sm:px-16 lg:px-0 gap-4 lg:gap-0 lg:flex-row">
          <TestimonialBox
            authorTitle={customerData[1].authorTitle}
            desc={customerData[1].desc}
            fontSize="lg"
            authorImage={customerData[1].authorImage}
            authorName={customerData[1].authorName}
          />
          <div className="flex flex-col pl-0 lg:pl-2 lg:gap-2 gap-4">
            <TestimonialBox
              fontSize="md"
              authorTitle={customerData[0].authorTitle}
              desc={customerData[0].desc}
              authorImage={customerData[0].authorImage}
              authorName={customerData[0].authorName}
            />
            <TestimonialBox
              fontSize="md"
              authorTitle={customerData[2].authorTitle}
              desc={customerData[2].desc}
              authorImage={customerData[2].authorImage}
              authorName={customerData[2].authorName}
            />
          </div>
        </div>
      </div>
    </section>
  );
}
