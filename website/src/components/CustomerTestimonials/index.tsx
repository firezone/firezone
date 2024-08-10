import Image from "next/image";
import Link from "next/link";
import { HiArrowLeft, HiArrowRight } from "react-icons/hi2";
import { manrope } from "@/lib/fonts";

const customerData = [
  {
    desc: "When producing live broadcasts for Fortune 500 companies security is of the utmost importance. We therefore selected Firezone for its robust WireGuard-based architecture. The flexible policy system and simple & clean user experience make Firezone the best fitting product for us in the market after trying several other solutions like Tailscale, OpenVPN, and Nebula.",
    authorName: "Robert Buisman",
    authorImage: "/images/portrait-robert-buisman.png",
    authorTitle: "CEO, NOMOBO",
  },
  {
    desc: "Firezone's easy-to-setup, sleek, and simple interface makes management effortless. It perfectly met our zero-trust security needs without the complexity found in other products we tested.",
    authorName: "Mark Sim",
    authorImage: "/images/portrait-mark-sim.jpg",
    authorTitle: "Technical Account Manager, Beakon",
  },
  {
    desc: "After comparing Tailscale, we ultimately chose Firezone to secure access to our data warehouses. Firezone's ease of configuration and robust policy-based access system made it the clear choice for our needs.",
    authorName: "James Winegar",
    authorImage: "/images/portrait-james-winegar.png",
    authorTitle: "CEO, Corrdyn",
  },
  {
    desc: "At Strong Compute, we have been using Firezone for over 3 years and it is still the most stable and best VPN solution we tested for remote access. It is fast, reliable and scalable to 10s of users. The team behind this are great and highly responsive to any queries or problems. I have moved other companies to Firezone and will continue to roll it out as my go-to VPN access and management solution.",
    authorName: "Cian Byrne",
    authorImage: "/images/portrait-cian-byrne.png",
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
    <div
      className={`flex flex-col justify-between text-neutral-50 bg-[#1B1B1D] rounded-2xl min-w-[540px] h-[350px] p-8 ${manrope.className}`}
    >
      <p className=" text-lg font-light text-pretty">"{desc}"</p>
      <div className="flex gap-4">
        <Image
          src={authorImage}
          alt="author portrait"
          width={42}
          height={42}
          className="rounded-full"
        />
        <div>
          <p className="text-lg">{authorName}</p>
          <p className="text-xs font-regular">{authorTitle}</p>
        </div>
      </div>
    </div>
  );
};

export default function CustomerTestimonials() {
  return (
    <section className="bg-black py-24 px-16">
      <div className="flex justify-between ">
        <h3
          className={` text-white text-3xl leading-5 md:text-4xl lg:text-5xl tracking-tight font-medium inline-block text-left my-2 ${manrope.className}`}
        >
          Why companies around the world prefer Firezone for protecting their
          workforce
        </h3>
        <div className="flex gap-12">
          <button className="w-9 h-9 flex justify-center items-center rounded-full bg-transparent border-[1px] border-neutral-700">
            <HiArrowLeft className="text-white w-5 h-5" />
          </button>
          <button className="w-9 h-9 flex justify-center items-center rounded-full bg-transparent border-[1px] border-neutral-700">
            <HiArrowRight className="text-white w-5 h-5" />
          </button>
        </div>
      </div>
      <div className="dark-scroll mt-12 flex gap-12 overflow-x-scroll pb-8 touch-pan-x touch-manipulation">
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
    </section>
  );
}
