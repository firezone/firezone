"use client";

import { Sidebar } from "flowbite-react";
import { usePathname } from "next/navigation";

export default function DocsSidebar() {
  const p = usePathname();

  return (
    <Sidebar>
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
