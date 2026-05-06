// Testimonial data lives in its own module so server components (e.g. the
// home page emitting Review JSON-LD) can import it without crossing the
// "use client" boundary of the rendering component.

import type { Route } from "next";
import { validUrl } from "@/lib/url";

export type CustomerTestimonial = {
  href: Route<string>;
  desc: string;
  authorName: string;
  companyName: string;
  authorImage: string;
  authorTitle: string;
};

export const customerTestimonials: CustomerTestimonial[] = [
  {
    href: validUrl("https://www.nomobo.tv/"),
    desc: `When producing live broadcasts for Fortune 500 companies security is of
      the utmost importance. We therefore selected Firezone for its robust
      WireGuard-based architecture. The flexible policy system and simple &
      clean user experience make Firezone the best fitting product for us in
      the market after trying several other solutions like Tailscale, OpenVPN,
      and Nebula.`,
    authorName: "Robert Buisman",
    companyName: "NOMOBO",
    authorImage: "/images/portrait-robert-buisman.png",
    authorTitle: "CEO",
  },
  {
    href: validUrl("https://beakon.com.au"),
    desc: `Firezone's easy-to-setup, sleek, and simple interface makes management
      effortless. It perfectly met our zero-trust security needs without the
      complexity found in other products we tested.`,
    authorName: "Mark Sim",
    companyName: "Beakon",
    authorImage: "/images/portrait-mark-sim.jpg",
    authorTitle: "Technical Account Manager",
  },
  {
    href: validUrl("https://www.corrdyn.com/"),
    desc: `After comparing Tailscale, we ultimately chose Firezone to secure access
      to our data warehouses. Firezone's ease of configuration and robust
      policy-based access system made it the clear choice for our needs.`,
    authorName: "James Winegar",
    companyName: "Corrdyn",
    authorImage: "/images/portrait-james-winegar.png",
    authorTitle: "CEO",
  },
  {
    href: validUrl("https://www.strongcompute.com/"),
    desc: `At Strong Compute, we have been using Firezone for over 3 years and it
      is still the most stable and best VPN solution we tested for remote access.`,
    authorName: "Cian Byrne",
    companyName: "Strong Compute",
    authorImage: "/images/portrait-cian-byrne.jpg",
    authorTitle: "Founding Engineer",
  },
];
