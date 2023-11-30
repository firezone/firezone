import Link from "next/link";
import Image from "next/image";
import gravatar from "@/lib/gravatar";
import { LinkedInIcon, GitHubIcon, TwitterIcon } from "@/components/Icons";

function renderTeamMember({
  name,
  title,
  imgSrc,
  twitterUrl,
  githubUrl,
  linkedinUrl,
}: {
  name: string;
  title: string;
  imgSrc: string;
  twitterUrl?: URL;
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
          {twitterUrl && (
            <li>
              <TwitterIcon url={twitterUrl} />
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

export default function Page() {
  const team = [
    {
      name: "Jamil Bou Kheir",
      title: "CEO/Founder",
      imgSrc: gravatar("jamil@firezone.dev", 200),
      twitterUrl: new URL("https://twitter.com/jamilbk"),
      githubUrl: new URL("https://github.com/jamilbk"),
      linkedinUrl: new URL("https://linkedin.com/in/jamilbk"),
    },
    {
      name: "Gabriel Steinberg",
      title: "Senior Backend Engineer",
      imgSrc: "/images/avatars/gabriel.png",
      twitterUrl: new URL("https://twitter.com/tapingmemory"),
      githubUrl: new URL("https://github.com/conectado"),
    },
    {
      name: "Andrew Dryga",
      title: "Founding Engineer",
      imgSrc: "/images/avatars/andrew.jpg",
      twitterUrl: new URL("https://twitter.com/andrew_dryga"),
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
      twitterUrl: new URL("https://twitter.com/oetzn"),
      githubUrl: new URL("https://github.com/thomaseizinger"),
      linkedinUrl: new URL("https://www.linkedin.com/in/thomas-eizinger"),
    },
    {
      name: "Roopesh Chander",
      title: "Apple Platform Engineer",
      imgSrc: gravatar("roop@roopc.net", 200),
      twitterUrl: new URL("https://twitter.com/roopcnet"),
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
      name: "Jeff Spencer",
      title: "Head of Marketing",
      imgSrc: gravatar("jeff@firezone.dev", 200),
      githubUrl: new URL("https://github.com/jefferenced"),
      linkedinUrl: new URL("https://www.linkedin.com/in/jeff393/"),
    },
    {
      name: "Trisha",
      title: "Windows Platform Engineer",
      imgSrc: gravatar("trish@firezone.dev", 200),
      githubUrl: new URL("https://github.com/ReactorScram"),
    },
  ];

  return (
    <section className="bg-neutral-100 ">
      <div className="py-8 px-4 mx-auto max-w-screen-lg text-center lg:py-16 lg:px-6">
        <div className="text-neutral-800 sm:text-lg ">
          <h1 className="mb-14 justify-center md:text-6xl text-5xl tracking-tight font-extrabold text-neutral-900 leading-none">
            Meet the Firezone team.
          </h1>
          <h2 className="mb-8 text-xl tracking-tight text-neutral-800 sm:px-16 xl:px-48">
            {/* FIXME: Make this less fluffy */}
            See the driving force behind Firezone -- a team dedicated to
            crafting secure and accessible software for a connected world.
            Committed to transparency and innovation, our diverse group of
            experts collaborates seamlessly to empower users with reliable and
            security-focused technology, redefining the way we connect in the
            digital landscape.
          </h2>
        </div>
        <div className="text-neutral-800 sm:text-lg ">
          <h3 className="justify-center pb-4 pt-14 text-2xl tracking-tight font-bold text-neutral-900  border-b border-neutral-300">
            THE FIREZONE TEAM
          </h3>
        </div>
        <div className="mt-16 grid sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4 md:gap-8 lg:gap-16">
          {team.map((person) => {
            return renderTeamMember(person);
          })}
        </div>
      </div>
    </section>
  );
}
