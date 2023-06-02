"use client";

import { Sidebar } from "flowbite-react";
import { usePathname } from "next/navigation";

export default function DocsSidebar() {
  const p = usePathname();

  return (
    <Sidebar className="fixed top-0 left-0 z-40 w-64 h-screen pt-14 transition-transform -translate-x-full bg-white border-r border-gray-200 md:translate-x-0 dark:bg-gray-800 dark:border-gray-700">
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
  );
}
