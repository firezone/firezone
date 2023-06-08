import { ChevronRightIcon, ChevronDownIcon } from "@heroicons/react/24/solid";

export default function Collapse({
  children,
  label,
}: {
  children: React.ReactNode;
  label: string;
}) {
  const ctl = label.toLowerCase().replace(" ", "-") + "-dropdown";
  return (
    <>
      <button
        type="button"
        className="flex items-center w-full p-2 text-gray-900 transition duration-75 rounded-lg group hover:bg-gray-100 dark:text-white dark:hover:bg-gray-700"
        aria-controls={ctl}
        data-collapse-toggle={ctl}
      >
        <span
          className="flex-1 ml-3 text-left whitespace-nowrap"
          sidebar-toggle-item="true"
        >
          {label}
        </span>
        <ChevronRightIcon sidebar-toggle-item="true" className="w-6 h-6" />
      </button>
      <ul id={ctl} className="hidden py-2 space-y-2">
        {children}
      </ul>
    </>
  );
}
