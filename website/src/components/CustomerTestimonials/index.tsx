"use client";

import Image from "next/image";
import Link from "next/link";
import { FaQuoteLeft } from "react-icons/fa";
import { FaHeart } from "react-icons/fa";
import ActionLink from "@/components/ActionLink";
import { Route } from "next";
import { customerTestimonials } from "./data";

interface TestimonialBoxProps {
  href: Route<string>;
  desc: string;
  authorImage: string;
  authorName: string;
  companyName: string;
  authorTitle: string;
  fontSize: string;
}

const TestimonialBox = ({
  href,
  desc,
  authorImage,
  authorName,
  companyName,
  authorTitle,
  fontSize,
}: TestimonialBoxProps) => {
  return (
    <div className="shrink-0 p-6 md:p-8 bg-[#1B1B1D] flex flex-col rounded-2xl justify-between w-fit lg:max-w-[320px] xl:max-w-[340px] lg:min-h-[320px] h-fit">
      <FaQuoteLeft className="absolute text-white/10 -translate-y-1/3 -z-1 w-10 h-10 sm:h-12 md:h-12 md:w-12" />
      <p
        className={`text-md  ${fontSize === "md" ? "lg:text-md" : "lg:text-lg"}
         tracking-wide font-light mb-6 break-keep italic text-neutral-50 z-10`}
      >
        &quot;{desc}&quot;
      </p>
      <div className="flex gap-4 items-center">
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
            {authorTitle},{" "}
            <Link
              href={href}
              className="underline hover:no-underline"
              target="_blank"
            >
              {companyName}
            </Link>
          </p>
        </div>
      </div>
    </div>
  );
};

export default function CustomerTestimonials() {
  return (
    <section className="bg-neutral-950 py-24 flex justify-center">
      <div className="relative flex flex-col lg:flex-row items-start lg:items-center justify-center max-w-screen-2xl">
        <div className="px-4 sm:px-16 lg:px-10 xl:px-0 xl:pr-16 mb-12 md:mb-16">
          <div>
            <h3 className="text-white text-3xl leading-5 md:text-4xl lg:text-5xl tracking-tight font-medium inline-block text-left mb-2">
              Customers{" "}
              <FaHeart className="text-primary-450 w-12 h-12 mx-1 inline-block" />{" "}
              us,
            </h3>
            <h3 className="text-neutral-600 text-3xl md:text-4xl leading-12 xl:text-5xl text-wrap sm:text-nowrap tracking-tight font-medium mb-6">
              and we love them back.
            </h3>
            <ActionLink
              href="/contact/sales"
              color="neutral-100"
              transitionColor="primary-450"
              size="lg"
            >
              Book a demo
            </ActionLink>
          </div>
        </div>
        <div className="flex flex-col items-center px-4 sm:px-16 lg:px-0 gap-4 lg:gap-0 lg:flex-row">
          <TestimonialBox
            authorTitle={customerTestimonials[1].authorTitle}
            desc={customerTestimonials[1].desc}
            companyName={customerTestimonials[1].companyName}
            fontSize="lg"
            href={customerTestimonials[1].href}
            authorImage={customerTestimonials[1].authorImage}
            authorName={customerTestimonials[1].authorName}
          />
          <div className="flex flex-col pl-0 lg:pl-2 lg:gap-2 gap-4">
            <TestimonialBox
              fontSize="md"
              href={customerTestimonials[0].href}
              authorTitle={customerTestimonials[0].authorTitle}
              desc={customerTestimonials[0].desc}
              companyName={customerTestimonials[0].companyName}
              authorImage={customerTestimonials[0].authorImage}
              authorName={customerTestimonials[0].authorName}
            />
            <TestimonialBox
              fontSize="md"
              href={customerTestimonials[2].href}
              authorTitle={customerTestimonials[2].authorTitle}
              desc={customerTestimonials[2].desc}
              companyName={customerTestimonials[2].companyName}
              authorImage={customerTestimonials[2].authorImage}
              authorName={customerTestimonials[2].authorName}
            />
          </div>
        </div>
      </div>
    </section>
  );
}
