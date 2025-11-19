"use client";
import { Route } from "next";
import { usePathname } from "next/navigation";
import type { CustomFlowbiteTheme } from "flowbite-react/types";
import {
  Sidebar as FlowbiteSidebar,
  SidebarItem as FlowbiteSidebarItem,
  SidebarItems as FlowbiteSidebarItems,
  SidebarItemGroup as FlowbiteSidebarItemGroup,
  SidebarCollapse as FlowbiteSidebarCollapse,
} from "flowbite-react";
import Link from "next/link";
import { useDrawer } from "@/components/Providers/DrawerProvider";

const ItemGroupLabelTheme: CustomFlowbiteTheme["sidebar"] = {
  item: {
    base: "flex items-center justify-center rounded-sm p-2 text-sm font-semibold uppercase text-primary-450",
  },
};

const FlowbiteSidebarTheme: CustomFlowbiteTheme["sidebar"] = {
  root: {
    base: "h-[calc(100vh)] left-0 top-0 z-40 sticky bg-white transition-transform pt-16 pb-8",
    collapsed: {
      on: "w-16",
      off: "w-64",
    },
    inner:
      "h-full overflow-y-auto overflow-x-hidden bg-white rounded-sm px-3 py-4 dark:bg-neutral-800",
  },
  collapse: {
    button:
      "group flex w-full items-center rounded-sm p-2 text-base font-normal text-neutral-900 transition duration-75 hover:bg-neutral-100 dark:text-white dark:hover:bg-neutral-700",
    icon: {
      base: "h-6 w-6 text-neutral-500 transition duration-75 group-hover:text-neutral-900 dark:text-neutral-400 dark:group-hover:text-white",
      open: {
        off: "",
        on: "text-neutral-900 dark:text-white",
      },
    },
    label: {
      base: "ml-3 flex-1 whitespace-nowrap text-left",
      icon: {
        base: "h-6 w-6 transition delay-0 ease-in-out",
        open: {
          on: "rotate-180",
          off: "",
        },
      },
    },
    list: "space-y-2 py-2",
  },
  cta: {
    base: "mt-6 rounded-lg bg-neutral-100 p-4 dark:bg-neutral-700",
    color: {
      blue: "bg-cyan-50 dark:bg-cyan-900",
      dark: "bg-dark-50 dark:bg-dark-900",
      failure: "bg-red-50 dark:bg-red-900",
      neutral: "bg-alternative-50 dark:bg-alternative-900",
      green: "bg-green-50 dark:bg-green-900",
      light: "bg-light-50 dark:bg-light-900",
      red: "bg-red-50 dark:bg-red-900",
      purple: "bg-purple-50 dark:bg-purple-900",
      success: "bg-green-50 dark:bg-green-900",
      yellow: "bg-yellow-50 dark:bg-yellow-900",
      warning: "bg-yellow-50 dark:bg-yellow-900",
    },
  },
  item: {
    base: "flex items-center justify-center rounded-sm p-2 text-base font-normal text-neutral-900 hover:bg-neutral-100 dark:text-white dark:hover:bg-neutral-700",
    active: "bg-neutral-200 dark:bg-neutral-700",
    collapsed: {
      insideCollapse: "group w-full pl-8 transition duration-75",
      noIcon: "font-bold",
    },
    content: {
      base: "flex-1 whitespace-nowrap px-3",
    },
    icon: {
      base: "h-6 w-6 shrink-0 text-neutral-500 transition duration-75 group-hover:text-neutral-900 dark:text-neutral-400 dark:group-hover:text-white",
      active: "text-neutral-700 dark:text-neutral-100",
    },
    label: "",
    listItem: "",
  },
  items: {
    base: "",
  },
  itemGroup: {
    base: "mt-4 space-y-2 border-t border-neutral-200 pt-4 first:mt-0 first:border-t-0 first:pt-0 dark:border-neutral-700",
  },
  logo: {
    base: "mb-5 flex items-center pl-2.5",
    collapsed: {
      on: "hidden",
      off: "self-center whitespace-nowrap text-xl font-semibold dark:text-white",
    },
    img: "mr-3 h-6 sm:h-7",
  },
};

const applyTheme = (isShown: boolean) => {
  return {
    ...FlowbiteSidebarTheme,
    root: {
      ...FlowbiteSidebarTheme.root,
      base: `${FlowbiteSidebarTheme.root?.base} ${isShown ? "translate-x-0" : "-translate-x-full"}`,
    },
  };
};

export function SidebarItem({
  href,
  children,
}: {
  href?: URL | Route<string>;
  children: React.ReactNode;
}) {
  const p = usePathname();

  if (href) {
    const hrefString = href instanceof URL ? href.toString() : href;
    const hrefPath = href instanceof URL ? href.pathname : href;
    return (
      <FlowbiteSidebarItem as={Link} href={hrefString} active={p === hrefPath}>
        {children}
      </FlowbiteSidebarItem>
    );
  } else {
    return <FlowbiteSidebarItem>{children}</FlowbiteSidebarItem>;
  }
}

export function SidebarItems({ children }: { children: React.ReactNode }) {
  return <FlowbiteSidebarItems>{children}</FlowbiteSidebarItems>;
}

export function SidebarItemGroup({
  label,
  children,
}: {
  label?: string;
  children: React.ReactNode;
}) {
  return (
    <FlowbiteSidebarItemGroup>
      {label && (
        <FlowbiteSidebarItem theme={ItemGroupLabelTheme?.item}>
          {label}
        </FlowbiteSidebarItem>
      )}
      {children}
    </FlowbiteSidebarItemGroup>
  );
}

export function SidebarCollapse({
  prefix,
  label,
  children,
}: {
  prefix: string;
  label: string;
  children: React.ReactNode;
}) {
  const p = usePathname();

  return (
    <FlowbiteSidebarCollapse open={p.startsWith(prefix)} label={label}>
      {children}
    </FlowbiteSidebarCollapse>
  );
}

export function Sidebar({ children }: { children: React.ReactNode }) {
  const { isShown } = useDrawer();

  return (
    <FlowbiteSidebar
      id="sidebar"
      theme={applyTheme(isShown)}
      aria-label="FlowbiteSidebar"
    >
      {children}
    </FlowbiteSidebar>
  );
}
