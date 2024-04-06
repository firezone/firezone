"use client";
import { HiXMark } from "react-icons/hi2";
import { useEffect } from "react";
import { initFlowbite } from "flowbite";

export default function Banner({
  active,
  overlay,
  children,
}: {
  active: boolean;
  overlay?: boolean;
  children: React.ReactNode;
}) {
  useEffect(() => {
    // Manually init flowbite's data-toggle listeners since we're using custom components
    initFlowbite();
  }, []);
  const position = overlay ? "fixed" : "relative";

  if (!active) return null;

  return (
    <div
      id="banner"
      tabIndex={-1}
      className={
        position +
        " flex top-14 z-30 justify-between items-start py-2 px-4 w-full bg-primary-450 shadow-lg sm:items-center  "
      }
    >
      {children}
      <button
        data-collapse-toggle="banner"
        type="button"
        className="flex items-center text-neutral-50 hover:bg-neutral-50 hover:text-neutral-900 rounded text-sm p-0.5  "
      >
        <HiXMark className="w-5 h-5" />
      </button>
    </div>
  );
}
