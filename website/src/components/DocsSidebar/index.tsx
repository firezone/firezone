"use client";
import Link from "next/link";
import type { CustomFlowbiteTheme } from "flowbite-react";
import { Flowbite } from "flowbite-react";
import { Sidebar } from "flowbite-react";
import { usePathname } from "next/navigation";
import { useEffect } from "react";
import { initFlowbite } from "flowbite";

// Overrides the default spacing to condense things a bit.
// See https://github.com/themesberg/flowbite-react/blob/main/src/theme.ts
const theme: CustomFlowbiteTheme = {
  sidebar: {
    root: {
      base: "z-40 w-64 h-screen pt-14 transition-transform -translate-x-full bg-white border-r border-gray-200 sm:translate-x-0 dark:bg-gray-800 dark:border-gray-700",
    },
    item: {
      base: "flex items-center justify-center rounded-lg p-0 text-base font-normal text-gray-900 hover:bg-gray-100 dark:text-white dark:hover:bg-gray-700",
      collapsed: {
        insideCollapse: "group w-full pl-3 transition duration-75",
      },
    },
    collapse: {
      button:
        "group flex w-full items-center rounded-lg p-0 text-base font-normal text-gray-900 transition duration-75 hover:bg-gray-100 dark:text-white dark:hover:bg-gray-700",
      label: {
        base: "ml-3 flex-1 whitespace-nowrap text-left",
      },
      list: "space-y-1 py-1",
    },
  },
};

export default function DocsSidebar() {
  const p = usePathname();

  function active(path: string) {
    return p == path ? "bg-gray-100 dark:bg-gray-700 " : "";
  }

  useEffect(() => {
    // Manually init flowbite's data-toggle listeners since we're using custom components
    initFlowbite();
  }, []);

  return (
    <aside
      id="docs-sidebar"
      aria-label="Sidebar"
      aria-hidden="true"
      className="z-40 fixed top-0 left-0 w-64 h-screen pt-14 transition-transform -translate-x-full bg-white border-r border-gray-200 md:translate-x-0 dark:bg-gray-800 dark:border-gray-700"
    >
      <div className="h-full overflow-y-auto bg-white dark:bg-gray-800">
        <ul className="space-y-2 font-medium">
          <li>
            <Link
              href="/docs"
              className={
                active("/docs") +
                "flex items-center justify-left rounded-lg p-0 text-base font-normal text-gray-900 hover:bg-gray-100 dark:text-white dark:hover:bg-gray-700"
              }
            >
              <span className="ml-3">Overview</span>
            </Link>
          </li>
          <li>
            <button
              type="button"
              className="flex items-center w-full p-2 text-gray-900 transition duration-75 rounded-lg group hover:bg-gray-100 dark:text-white dark:hover:bg-gray-700"
              aria-controls="deploy-dropdown"
              data-collapse-toggle="deploy-dropdown"
            >
              <span
                className="flex-1 ml-3 text-left whitespace-nowrap"
                sidebar-toggle-item
              >
                Deploy
              </span>
              <svg
                sidebar-toggle-item
                className="w-6 h-6"
                fill="currentColor"
                viewBox="0 0 20 20"
                xmlns="http://www.w3.org/2000/svg"
              >
                <path
                  fillRule="evenodd"
                  d="M5.293 7.293a1 1 0 011.414 0L10 10.586l3.293-3.293a1 1 0 111.414 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 010-1.414z"
                  clipRule="evenodd"
                ></path>
              </svg>
            </button>
            <ul id="deploy-dropdown" className="hidden py-2 space-y-2">
              <li>
                <Link
                  href="/docs/deploy"
                  className={
                    active("/docs/deploy") +
                    "flex items-center justify-left rounded-lg p-0 text-base font-normal text-gray-900 hover:bg-gray-100 dark:text-white dark:hover:bg-gray-700"
                  }
                >
                  <span className="ml-3">Overview</span>
                </Link>
              </li>
              <li>
                <button
                  type="button"
                  className="flex items-center w-full p-2 text-gray-900 transition duration-75 rounded-lg group hover:bg-gray-100 dark:text-white dark:hover:bg-gray-700"
                  aria-controls="deploy-docker-dropdown"
                  data-collapse-toggle="deploy-docker-dropdown"
                >
                  <span
                    className="flex-1 ml-3 text-left whitespace-nowrap"
                    sidebar-toggle-item
                  >
                    Docker
                  </span>
                  <svg
                    sidebar-toggle-item
                    className="w-6 h-6"
                    fill="currentColor"
                    viewBox="0 0 20 20"
                    xmlns="http://www.w3.org/2000/svg"
                  >
                    <path
                      fillRule="evenodd"
                      d="M5.293 7.293a1 1 0 011.414 0L10 10.586l3.293-3.293a1 1 0 111.414 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 010-1.414z"
                      clipRule="evenodd"
                    ></path>
                  </svg>
                </button>
              </li>
              <li>
                <button
                  type="button"
                  className="flex items-center w-full p-2 text-gray-900 transition duration-75 rounded-lg group hover:bg-gray-100 dark:text-white dark:hover:bg-gray-700"
                  aria-controls="deploy-omnibus-dropdown"
                  data-collapse-toggle="deploy-omnibus-dropdown"
                >
                  <span
                    className="flex-1 ml-3 text-left whitespace-nowrap"
                    sidebar-toggle-item
                  >
                    Omnibus
                  </span>
                  <svg
                    sidebar-toggle-item
                    className="w-6 h-6"
                    fill="currentColor"
                    viewBox="0 0 20 20"
                    xmlns="http://www.w3.org/2000/svg"
                  >
                    <path
                      fillRule="evenodd"
                      d="M5.293 7.293a1 1 0 011.414 0L10 10.586l3.293-3.293a1 1 0 111.414 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 010-1.414z"
                      clipRule="evenodd"
                    ></path>
                  </svg>
                </button>
              </li>
            </ul>
          </li>
        </ul>
      </div>
    </aside>
  );
}
