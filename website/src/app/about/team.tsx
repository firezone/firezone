import gravatar from "@/lib/gravatar";
import { LinkedInIcon, GitHubIcon, XIcon } from "@/components/Icons";
import Image from "next/image";
import Link from "next/link";

function teamMember({
  name,
  title,
  imgSrc,
  xUrl,
  githubUrl,
  linkedinUrl,
}: {
  name: string;
  title: string;
  imgSrc: string;
  xUrl?: URL;
  githubUrl?: URL;
  linkedinUrl?: URL;
}) {
  return (
    <div className="text-center">
      <Image
        width={144}
        height={144}
        className="shadow-lg hover:scale-105 duration-0 transform transition mx-auto mb-4 w-36 h-36 rounded-full"
        src={imgSrc}
        alt={`{name} Avatar`}
      />
      <div className="text-center">
        <h3 className="justify-center text-xl font-bold tracking-tight text-neutral-900 ">
          {name}
        </h3>
        <span className="text-neutral-800 text-sm">{title}</span>
        <ul className="flex justify-center space-x-4 mt-4">
          {xUrl && (
            <li>
              <XIcon url={xUrl} />
            </li>
          )}
          {githubUrl && (
            <li>
              <GitHubIcon url={githubUrl} />
            </li>
          )}
          {linkedinUrl && (
            <li>
              <LinkedInIcon url={linkedinUrl} />
            </li>
          )}
        </ul>
      </div>
    </div>
  );
}
export default function Team() {
  const team = [
    {
      name: "Jamil Bou Kheir",
      title: "CEO/Founder",
      imgSrc: gravatar("jamil@firezone.dev", 200),
      xUrl: new URL("https://x.com/jamilbk"),
      githubUrl: new URL("https://github.com/jamilbk"),
      linkedinUrl: new URL("https://linkedin.com/in/jamilbk"),
    },
    {
      name: "Gabriel Steinberg",
      title: "Senior Backend Engineer",
      imgSrc: "/images/avatars/gabriel.png",
      xUrl: new URL("https://x.com/tapingmemory"),
      githubUrl: new URL("https://github.com/conectado"),
    },
    {
      name: "Andrew Dryga",
      title: "Founding Engineer",
      imgSrc: "/images/avatars/andrew.jpg",
      xUrl: new URL("https://x.com/andrew_dryga"),
      githubUrl: new URL("https://github.com/andrewdryga"),
      linkedinUrl: new URL("https://linkedin.com/in/andrew-dryga-bb382557"),
    },
    {
      name: "Blake Hitchcock",
      title: "Technical Advisor",
      imgSrc: "/images/avatars/blake.jpeg",
      githubUrl: new URL("https://github.com/rbhitchcock"),
      linkedinUrl: new URL("https://www.linkedin.com/in/rblakehitchcock"),
    },
    {
      name: "Thomas Eizinger",
      title: "Distributed Systems Engineer",
      imgSrc: "/images/avatars/thomas.jpeg",
      xUrl: new URL("https://x.com/oetzn"),
      githubUrl: new URL("https://github.com/thomaseizinger"),
      linkedinUrl: new URL("https://www.linkedin.com/in/thomas-eizinger"),
    },
    {
      name: "Roopesh Chander",
      title: "Apple Platform Engineer",
      imgSrc: gravatar("roop@roopc.net", 200),
      xUrl: new URL("https://x.com/roopcnet"),
      githubUrl: new URL("https://github.com/roop"),
    },
    {
      name: "Brian Manifold",
      title: "Senior Full-stack Engineer",
      imgSrc: "/images/avatars/brian.png",
      githubUrl: new URL("https://github.com/bmanifold"),
      linkedinUrl: new URL(
        "https://www.linkedin.com/in/brian-manifold-536a0a3a/"
      ),
    },
    {
      name: "Trisha",
      title: "Senior Systems Engineer",
      imgSrc: gravatar("trish@firezone.dev", 200),
      githubUrl: new URL("https://github.com/ReactorScram"),
    },
    {
      name: "Robert Laurence",
      title: "Advisor",
      imgSrc: gravatar("rb.laur@gmail.com"),
    },
  ];

  return (
    <section className="border-t border-neutral-200 bg-neutral-100">
      <div className="py-8 px-4 mx-auto max-w-screen-lg text-center lg:py-16 lg:px-6">
        <div className="border-b text-neutral-800 sm:text-lg">
          <h2 className="mb-14 justify-center md:text-5xl text-4xl tracking-tight font-extrabold text-neutral-900 leading-none">
            Meet the team.
          </h2>
          <p className="mb-8 text-xl tracking-tight text-neutral-800 sm:px-16 xl:px-32">
            Firezone is built by a global team of motivated individuals. Our
            passion for security, reliability, and code quality permeates
            everything we do, and since we’re open source, you can{" "}
            <Link
              href={new URL("https://github.com/firezone/firezone")}
              className="hover:underline text-accent-500"
            >
              see for yourself
            </Link>
            . The team has experience building enterprise networking solutions
            at companies like Cisco, Marqeta, Instacart, and more.
          </p>
        </div>
        <div className="mt-16 grid sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4 md:gap-8 lg:gap-16">
          {team.map((person) => {
            return teamMember(person);
          })}
        </div>
      </div>
    </section>
  );
}
