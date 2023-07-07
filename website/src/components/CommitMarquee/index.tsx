"use client";

import Link from "next/link";
import Image from "next/image";
import { XMLParser } from "fast-xml-parser";
import { useState, useEffect } from "react";
import Marquee from "react-fast-marquee";

export default function CommitMarquee({ xmlFeed }: { xmlFeed: string }) {
  const parser = new XMLParser({ ignoreAttributes: false });
  const [xml, setXml] = useState<any>({ feed: { title: "", entry: [] } });

  useEffect(() => {
    fetch(xmlFeed)
      .then((response) => response.text())
      .then((str) => parser.parse(str))
      .then((data) => {
        setXml(data);
      })
      .catch((error) => console.error(error));
  }, []);

  return (
    <div>
      <h3 className="justify-center sm:text-2xl text-xl font-bold tracking-tight text-neutral-900 mb-4 sm:mb-6 border-b pb-2 border-neutral-300">
        {xml.feed.title}
      </h3>
      <Marquee
        gradient
        pauseOnHover
        gradientWidth={100}
        gradientColor={[248, 247, 247]}
      >
        {xml.feed.entry.map((entry: any) => (
          <div
            key={entry.id}
            className="text-center w-64 h-full items-top mx-2 py-2 px-2"
          >
            <h4 className="justify-center mb-2 text-neutral-800 dark:text-neutral-200 font-medium text-lg">
              <Link
                href={entry.link["@_href"]}
                className="text-accent-500 underline hover:no-underline"
              >
                {entry.title.replace(/\(#.*\)/, "")}
              </Link>
            </h4>
            <p className="mb-2 text-center">
              <Image
                className="rounded-full mx-auto"
                width={entry["media:thumbnail"]["@_width"]}
                height={entry["media:thumbnail"]["@_height"]}
                src={entry["media:thumbnail"]["@_url"]}
                alt="user avatar"
              />
            </p>
            <p className="mb-2 text-sm">
              <Link
                href={entry.author.uri}
                className="text-accent-500 underline hover:no-underline"
              >
                {entry.author.name}
              </Link>{" "}
            </p>
            <p className="font-semibold text-xs">
              {new Date(entry.updated).toDateString()}
            </p>
          </div>
        ))}
      </Marquee>
    </div>
  );
}
