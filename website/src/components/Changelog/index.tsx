"use client";

import { TabsGroup, TabsItem } from "@/components/Tabs";
import Link from "next/link";
import Android from "./Android";
import Apple from "./Apple";
import Gateway from "./Gateway";
import GUI from "./GUI";
import Headless from "./Headless";
import { HiServerStack } from "react-icons/hi2";
import { FaApple, FaAndroid, FaWindows, FaLinux } from "react-icons/fa";
import { useEffect, useState } from "react";

export default function Changelog() {
  const [sha, setSha] = useState<string | undefined>(undefined);

  useEffect(() => {
    const fetchSha = async () => {
      const response = await fetch("/api/releases");
      const versions = await response.json();
      setSha(versions.portal);
    };
    fetchSha();
  }, []);

  return (
    <section className="mx-auto max-w-xl md:max-w-screen-xl">
      <TabsGroup>
        <TabsItem title="Gateway" icon={HiServerStack}>
          <Gateway />
        </TabsItem>
        <TabsItem title="macOS / iOS" icon={FaApple}>
          <Apple />
        </TabsItem>
        <TabsItem title="Windows GUI" icon={FaWindows}>
          <GUI os={OS.Windows} />
        </TabsItem>
        <TabsItem title="Windows Headless" icon={FaWindows}>
          <Headless os={OS.Windows} />
        </TabsItem>
        <TabsItem title="Android" icon={FaAndroid}>
          <Android />
        </TabsItem>
        <TabsItem title="Linux GUI" icon={FaLinux}>
          <GUI os={OS.Linux} />
        </TabsItem>
        <TabsItem title="Linux Headless" icon={FaLinux}>
          <Headless os={OS.Linux} />
        </TabsItem>
      </TabsGroup>
      {sha && (
        <p className="text-sm md:text-lg mt-4 md:mt-8">
          Current SHA of Portal and Relays in production:{" "}
          <Link
            href={`https://www.github.com/firezone/firezone/tree/${sha}`}
            className="underline hover:no-underline text-accent-500"
          >
            {sha}
          </Link>
          .
        </p>
      )}
    </section>
  );
}

export enum OS {
  Windows,
  Linux,
}
