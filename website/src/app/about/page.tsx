import Link from "next/link";
import Image from "next/image";
import Hero from "./hero";
import Story from "./story";
import Mission from "./mission";
import Principles from "./principles";
import Investors from "./investors";
import Team from "./team";
import Contact from "./contact";

export default function Page() {
  return (
    <>
      <Hero />
      <Story />
      <Mission />
      <Principles />
      <Investors />
      <Team />
      <Contact />
    </>
  );
}
