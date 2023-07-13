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
  twitterUrl?: string;
  githubUrl?: string;
  linkedinUrl?: string;
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
        <h3 className="justify-center text-xl font-bold tracking-tight text-neutral-900 dark:text-white">
          {name}
        </h3>
        <span className="text-neutral-800 dark:text-neutral-100">{title}</span>
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
  const coreTeam = [
    {
      name: "Jamil Bou Kheir",
      title: "CEO/Founder",
      imgSrc: gravatar("jamil@firezone.dev", 200),
      twitterUrl: "https://twitter.com/jamilbk",
      githubUrl: "https://github.com/jamilbk",
      linkedinUrl: "https://linkedin.com/in/jamilbk",
    },
    {
      name: "Gabriel Steinberg",
      title: "Senior Backend Engineer",
      imgSrc: "/images/avatars/gabriel.png",
      twitterUrl: "https://twitter.com/tapingmemory",
      githubUrl: "https://github.com/conectado",
    },
    {
      name: "Andrew Dryga",
      title: "Founding Engineer",
      imgSrc: "/images/avatars/andrew.jpg",
      twitterUrl: "https://twitter.com/andrew_dryga",
      githubUrl: "https://github.com/andrewdryga",
      linkedinUrl: "https://linkedin.com/in/andrew-dryga-bb382557",
    },
    {
      name: "Francesca Lovebloom",
      title: "Senior Systems Engineer",
      imgSrc: gravatar("fran@firezone.dev", 200),
      twitterUrl: "https://twitter.com/franlovebloom",
      githubUrl: "https://github.com/francesca64",
      linkedinUrl: "https://linkedin.com/in/francesca-lovebloom",
    },
    {
      name: "Brian Manifold",
      title: "Senior Full-stack Engineer",
      imgSrc: "/images/avatars/brian.png",
      githubUrl: "https://github.com/bmanifold",
      linkedinUrl: "https://www.linkedin.com/in/brian-manifold-536a0a3a/",
    },
  ];

  const advisors = [
    {
      name: "Blake Hitchcock",
      title: "Technical Advisor",
      imgSrc: "/images/avatars/blake.jpeg",
      githubUrl: "https://github.com/rbhitchcock",
      linkedinUrl: "https://www.linkedin.com/in/rblakehitchcock",
    },
    {
      name: "Thomas Eizinger",
      title: "Technical Consultant",
      imgSrc: "/images/avatars/thomas.jpeg",
      twitterUrl: "https://twitter.com/oetzn",
      githubUrl: "https://github.com/thomaseizinger",
      linkedinUrl: "https://www.linkedin.com/in/thomas-eizinger",
    },
    {
      name: "Roopesh Chander",
      title: "Technical Consultant",
      imgSrc: gravatar("roop@roopc.net", 200),
      twitterUrl: "https://twitter.com/roopcnet",
      githubUrl: "https://github.com/roop",
    },
  ];

  return (
    <section className="bg-neutral-50 dark:bg-neutral-900">
      <div className="py-8 px-4 mx-auto max-w-screen-lg text-center lg:py-16 lg:px-6">
        <div className="text-neutral-800 sm:text-lg dark:text-neutral-100">
          <h2 className="mb-14 justify-center text-6xl tracking-tight font-extrabold text-neutral-900 dark:text-white">
            People are everything.
          </h2>
          <p className="mb-4 sm:text-2xl">
            Here at Firezone we know that it's people who make all the
            difference.
            <br /> We strive to hire the best and brightest and give them the
            tools they need to succeed.
          </p>
        </div>
        <div className="text-neutral-800 sm:text-lg dark:text-neutral-100">
          <h3 className="justify-center pb-4 pt-14 text-2xl tracking-tight font-bold text-neutral-900 dark:text-white border-b border-neutral-300">
            CORE TEAM
          </h3>
        </div>
        <div className="mt-16 grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4 md:gap-8 lg:gap-16">
          {coreTeam.map((person) => {
            return renderTeamMember(person);
          })}
        </div>
        <div className="text-neutral-800 sm:text-lg dark:text-neutral-100">
          <h3 className="justify-center pb-4 pt-14 text-2xl tracking-tight font-bold text-neutral-900 dark:text-white border-b border-neutral-300">
            ADVISORS & CONSULTANTS
          </h3>
        </div>
        <div className="mt-16 grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-8 lg:gap-16">
          {advisors.map((person) => {
            return renderTeamMember(person);
          })}
        </div>
      </div>
    </section>
  );
}
