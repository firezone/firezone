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

export default function Changelog() {
  const sha = process.env.FIREZONE_DEPLOYED_SHA;

  return (
    <section className="mx-auto max-w-xl md:max-w-screen-xl">
      <TabsGroup>
        <TabsItem title="Gateway" icon={HiServerStack}>
          <Gateway />
        </TabsItem>
        <TabsItem title="Linux GUI" icon={FaLinux}>
          <GUI title="Linux GUI" />
        </TabsItem>
        <TabsItem title="Apple" icon={FaApple}>
          <Apple />
        </TabsItem>
        <TabsItem title="Windows" icon={FaWindows}>
          <GUI title="Windows" />
        </TabsItem>
        <TabsItem title="Android" icon={FaAndroid}>
          <Android />
        </TabsItem>
        <TabsItem title="Linux Headless" icon={FaLinux}>
          <Headless />
        </TabsItem>
      </TabsGroup>
      {sha && (
        <p className="text-sm md:text-lg mt-4 md:mt-8">
          Current SHA of Portal and Relays in production is{" "}
          <Link
            href={"https://www.github.com/firezone/firezone/tree/#{sha}"}
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
