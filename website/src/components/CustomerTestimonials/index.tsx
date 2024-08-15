import Carousel from "@/components/Carousel";
import Image from "next/image";
import Link from "next/link";
import { HiArrowLeft, HiArrowRight } from "react-icons/hi2";
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
    <div className="h-full px-8 md:px-16 py-8 md:py-12">
      <div className="mb-4 md:mb-8">
        <p className="text-md md:text-lg tracking-wide font-light mb-2 md:mb-6 break-keep italic">
          "{desc}"
        </p>
      </div>
      <div className="flex gap-4 items-center">
        <Image
          src={authorImage}
          alt="author portrait"
          width={128}
          height={128}
          className="w-10 h-10 sm:h-12 sm:h-12 md:h-16 md:w-16 rounded-full"
        />
        <div className>
          <p className="text-md md:text-lg">{authorName}</p>
          <p className="text-sm md:text-md font-light">{authorTitle}</p>
        </div>
      </div>
    </div>
  );
};

export default function CustomerTestimonials() {
  return (
    <section className="bg-neutral-950 py-24 px-8 md:px-0">
      <div className="max-w-screen-md mx-auto">
        <h3
          className={`text-white text-3xl leading-5 md:text-4xl lg:text-5xl tracking-tight font-medium inline-block text-left mb-8 ${manrope.className}`}
        >
          Why choose Firezone?
        </h3>
        <Carousel>
          {customerData.map((item, index) => (
            <TestimonialBox
              key={index}
              authorTitle={item.authorTitle}
              desc={item.desc}
              authorImage={item.authorImage}
              authorName={item.authorName}
            />
          ))}
        </Carousel>
      </div>
    </section>
  );
}
