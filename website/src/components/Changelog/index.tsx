"use client";

import { TabsGroup, TabsItem } from "@/components/Tabs";
import Android from "./Android";
import Apple from "./Apple";
import Gateway from "./Gateway";
import GUI from "./GUI";
import Headless from "./Headless";
import { HiServerStack } from "react-icons/hi2";
import { FaApple, FaAndroid, FaWindows, FaLinux } from "react-icons/fa";

export default function Changelog() {
  return (
    <section className="mx-auto max-w-xl md:max-w-screen-xl">
      <TabsGroup>
        <TabsItem title="Gateway" icon={HiServerStack}>
          <Gateway />
        </TabsItem>
        <TabsItem title="Linux GUI" icon={FaLinux}>
          <GUI type="Linux GUI" />
        </TabsItem>
        <TabsItem title="Apple" icon={FaApple}>
          <Apple />
        </TabsItem>
        <TabsItem title="Windows" icon={FaWindows}>
          <GUI type="Windows" />
        </TabsItem>
        <TabsItem title="Android" icon={FaAndroid}>
          <Android />
        </TabsItem>
        <TabsItem title="Linux Headless" icon={FaLinux}>
          <Headless />
        </TabsItem>
      </TabsGroup>
    </section>
  );
}
