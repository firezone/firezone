import { ChevronRightIcon, ChevronDownIcon } from "@heroicons/react/20/solid";
import { useState } from "react";

export default function Collapse({
  children,
  label,
  expanded,
  level,
}: {
  children: React.ReactNode;
  label: string;
  expanded?: boolean;
  level?: number;
}) {
  const ctl = label.toLowerCase().replace(" ", "-") + "-dropdown";
  const indent = level ? "ml-" + level * 3 : "ml-3";
  const hidden = expanded ? "" : "hidden";
  const text = expanded
    ? "bg-gray-100 dark:bg-gray-700"
    : "text-gray-900 dark:text-white";
  const [expandedState, setExpandedState] = useState(expanded);

  return (
    <>
      <button
        type="button"
        className={
          text +
          " flex items-center w-full pt-0 transition duration-75 rounded-lg group hover:bg-gray-100 dark:hover:bg-gray-700"
        }
        aria-controls={ctl}
        data-collapse-toggle={ctl}
        onClick={() => setExpandedState(!expandedState)}
      >
        <span
          className={indent + " flex-1 text-left whitespace-nowrap"}
          sidebar-toggle-item="true"
        >
          {label}
        </span>
        {expandedState ? (
          <ChevronDownIcon sidebar-toggle-item="true" className="w-6 h-6" />
        ) : (
          <ChevronRightIcon sidebar-toggle-item="true" className="w-6 h-6" />
        )}
      </button>
      <ul id={ctl} className={hidden + " py-1 space-y-0.5"}>
        {children}
      </ul>
    </>
  );
}
