"use client";
import { Tabs as FlowbiteTabs } from "flowbite-react";

function TabsGroup({ children }: { children: React.ReactNode }) {
  return <FlowbiteTabs.Group className="mb-4">{children}</FlowbiteTabs.Group>;
}

function TabsItem({
  children,
  title,
  ...props
}: {
  children: React.ReactNode;
  title: string;
}) {
  return (
    <FlowbiteTabs.Item title={title} {...props}>
      {children}
    </FlowbiteTabs.Item>
  );
}

export { TabsGroup, TabsItem };
