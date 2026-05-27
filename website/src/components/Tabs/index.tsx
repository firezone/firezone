"use client";
import { Tabs, TabItem } from "flowbite-react";
import type { TabItemProps as FlowbiteTabItemProps } from "flowbite-react";
import type { CustomFlowbiteTheme } from "flowbite-react/types";
import { Children, isValidElement } from "react";
import type { ReactNode } from "react";
import {
  FaAndroid,
  FaApple,
  FaDocker,
  FaLinux,
  FaUbuntu,
  FaWindows,
} from "react-icons/fa";
import { HiCommandLine, HiServerStack } from "react-icons/hi2";

// Icons are looked up by string key rather than passed as component refs.
// Server components rendering MDX cannot pass function props (component
// references) into client components — RSC serialization rejects them.
// Using a string keeps the prop serializable so callers in server-rendered
// MDX (page.tsx → MDX → <TabsItem>) work without a "use client" page wrapper.
const TABS_ICONS = {
  android: FaAndroid,
  apple: FaApple,
  commandLine: HiCommandLine,
  docker: FaDocker,
  linux: FaLinux,
  serverStack: HiServerStack,
  ubuntu: FaUbuntu,
  windows: FaWindows,
} as const;

export type TabsItemIcon = keyof typeof TABS_ICONS;
type TabsItemProps = Omit<FlowbiteTabItemProps, "icon" | "title"> & {
  children: ReactNode;
  icon?: TabsItemIcon;
  title: FlowbiteTabItemProps["title"];
};

const customTheme: CustomFlowbiteTheme["tabs"] = {
  base: "flex flex-col gap-2",
  tablist: {
    base: "flex text-center",
    variant: {
      default: "flex-wrap border-b border-neutral-200",
      underline: "flex-wrap -mb-px border-b border-neutral-200",
      pills: "flex-wrap font-medium text-sm text-neutral-500 space-x-2",
      fullWidth:
        "w-full text-sm font-medium divide-x divide-neutral-200 shadow-sm grid grid-flow-colrounded-none",
    },
    tabitem: {
      base: "flex cursor-pointer items-center justify-center p-4 rounded-t-lg text-sm font-medium first:ml-0 disabled:cursor-not-allowed disabled:text-neutral-400",
      variant: {
        default: {
          base: "rounded-t-lg",
          active: {
            on: "bg-neutral-100 text-neutral-600",
            off: "text-neutral-500 hover:bg-neutral-50 hover:text-neutral-600",
          },
        },
        underline: {
          base: "rounded-t-lg cursor-pointer",
          active: {
            on: "text-accent-600 rounded-t-lg border-b-2 border-accent-600 active",
            off: "border-b-2 border-transparent text-neutral-500 hover:border-accent-200 hover:text-accent-600",
          },
        },
        pills: {
          base: "",
          active: {
            on: "rounded-lg bg-neutral-600 text-white",
            off: "rounded-lg hover:text-neutral-900 hover:bg-neutral-100",
          },
        },
        fullWidth: {
          base: "ml-0 first:ml-0 w-full rounded-none flex",
          active: {
            on: "p-4 text-neutral-900 bg-neutral-100 active rounded-none",
            off: "bg-white hover:text-neutral-700 hover:bg-neutral-50 rounded-none",
          },
        },
      },
      icon: "mr-2 h-5 w-5",
    },
  },
  tabitemcontainer: {
    base: "",
    variant: {
      default: "",
      underline: "",
      pills: "",
      fullWidth: "",
    },
  },
  tabpanel: "p-3",
};

function iconComponent(icon?: TabsItemIcon) {
  return icon ? TABS_ICONS[icon] : undefined;
}

function tabItemFromChild(child: ReactNode) {
  if (!isValidElement<TabsItemProps>(child)) {
    return null;
  }

  const { children, icon, ...props } = child.props;

  return (
    <TabItem {...props} icon={iconComponent(icon)}>
      {children}
    </TabItem>
  );
}

function TabsGroup({ children }: { children: ReactNode }) {
  return (
    <div className="mb-8">
      <Tabs theme={customTheme} variant="underline">
        {Children.map(children, tabItemFromChild)}
      </Tabs>
    </div>
  );
}

function TabsItem({ children, title, icon, ...props }: TabsItemProps) {
  return (
    <TabItem title={title} icon={iconComponent(icon)} {...props}>
      {children}
    </TabItem>
  );
}

export { TabsGroup, TabsItem };
