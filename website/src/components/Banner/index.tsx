"use client";
import { XMarkIcon } from "@heroicons/react/20/solid";
import { useEffect } from "react";
import { initFlowbite } from "flowbite";

export default function Banner({
  active,
  children,
}: {
  active: boolean;
  children: React.ReactNode;
}) {
  useEffect(() => {
    // Manually init flowbite's data-toggle listeners since we're using custom components
    initFlowbite();
  }, []);

  if (!active) return null;

  return (
    <div
      id="banner"
      tabIndex={-1}
      className="flex top-14 fixed z-50 gap-8 justify-between items-start py-2 px-4 w-full bg-primary-450 shadow-lg sm:items-center dark:border-neutral-700 dark:bg-neutral-800"
    >
      {children}
      <button
        data-collapse-toggle="banner"
        type="button"
        className="flex items-center text-neutral-50 hover:bg-neutral-50 hover:text-neutral-900 rounded-lg text-sm p-1.5 dark:hover:bg-neutral-900 dark:hover:text-neutral-50"
      >
        <XMarkIcon className="w-5 h-5" />
      </button>
    </div>
  );
}
