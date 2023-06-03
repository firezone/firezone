"use client";

import type { CustomFlowbiteTheme } from "flowbite-react";
import { Flowbite } from "flowbite-react";
import { Sidebar } from "flowbite-react";
import { usePathname } from "next/navigation";

// See https://github.com/themesberg/flowbite-react/blob/main/src/theme.ts
const theme: CustomFlowbiteTheme = {
  sidebar: {
    root: {
      base: "fixed top-0 left-0 z-40 w-64 h-screen pt-14 transition-transform -translate-x-full bg-white border-r border-gray-200 md:translate-x-0 dark:bg-gray-800 dark:border-gray-700",
    },
    item: {
      base: "flex items-center justify-center rounded-lg p-1 text-base font-normal text-gray-900 hover:bg-gray-100 dark:text-white dark:hover:bg-gray-700",
    },
  },
};

export default function DocsSidebar() {
  const p = usePathname();

  return (
    <Flowbite theme={{ theme: theme }}>
      <Sidebar aria-label="Docs Sidebar">
        <Sidebar.Items>
          <Sidebar.ItemGroup>
            <Sidebar.Item href="/docs" active={p == "/docs"}>
              Overview
            </Sidebar.Item>
            <Sidebar.Item href="/docs/deploy" active={p == "/docs/deploy"}>
              Deploy
            </Sidebar.Item>
          </Sidebar.ItemGroup>
        </Sidebar.Items>
      </Sidebar>
    </Flowbite>
  );
}
