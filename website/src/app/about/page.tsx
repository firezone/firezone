import { Metadata } from "next";
import Hero from "./hero";
import Story from "./story";
import Mission from "./mission";
import Principles from "./principles";
import Investors from "./investors";
import Contact from "./contact";

export const metadata: Metadata = {
  title: "About Our Zero Trust Access Company",
  description:
    "Meet the team building Firezone — the open-source zero trust access platform replacing legacy VPNs. Read our mission, principles, and story.",
};

export default function Page() {
  return (
    <>
      <Hero />
      <Story />
      <Mission />
      <Principles />
      <Investors />
      <Contact />
    </>
  );
}
