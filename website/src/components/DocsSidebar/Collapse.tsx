import { ChevronRightIcon, ChevronDownIcon } from "@heroicons/react/20/solid";
import { useState } from "react";

export default function Collapse({
  children,
  label,
  expanded,
}: {
  children: React.ReactNode;
  label: string;
  expanded?: boolean;
}) {
  const ctl = label.toLowerCase().replace(" ", "-") + "-dropdown";
  const indent = "ml-3";
  const hidden = expanded ? "" : "hidden";
  const text = expanded
    ? "bg-neutral-100 dark:bg-neutral-700"
    : "text-neutral-900 dark:text-white";
  const [expandedState, setExpandedState] = useState(expanded);

  return (
    <>
      <button
        type="button"
        className={
          text +
          " flex items-center w-full transition duration-75 rounded-lg group hover:bg-neutral-100 dark:hover:bg-neutral-700"
        }
        aria-controls={ctl}
        data-collapse-toggle={ctl}
        onClick={() => setExpandedState(!expandedState)}
      >
        <span
          className="ml-3 flex-1 text-left whitespace-nowrap"
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
      <ul id={ctl} className={[hidden, "ml-3 py-1 space-y-0.5"].join(" ")}>
        {children}
      </ul>
    </>
  );
}
