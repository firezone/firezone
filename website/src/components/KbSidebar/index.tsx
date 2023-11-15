"use client";
import Collapse from "./Collapse";
import { useEffect } from "react";
import { initFlowbite } from "flowbite";
import Item from "./Item";
import SearchForm from "./SearchForm";
import { usePathname } from "next/navigation";

export default function KbSidebar() {
  useEffect(() => {
    // Manually init flowbite's data-toggle listeners since we're using custom components
    initFlowbite();
  }, []);

  const p = usePathname() || "";

  return (
    <aside
      id="kb-sidebar"
      aria-label="Sidebar"
      aria-hidden="true"
      className="sticky left-0 top-0 flex-none w-64 h-screen pt-20 transition-transform -translate-x-full bg-white border-r border-neutral-200 md:translate-x-0  "
    >
      <SearchForm />
      <div className="mt-5 h-full overflow-y-auto bg-white  pr-3">
        <ul className="space-y-2 font-medium">{/* FIXME */}</ul>
      </div>
    </aside>
  );
}
