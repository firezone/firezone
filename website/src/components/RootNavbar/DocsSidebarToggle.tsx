import { usePathname } from "next/navigation";
import { HiBars3 } from "react-icons/hi2";

export default function DocsSidebarToggle() {
  const p = usePathname() || "";

  if (p.startsWith("/docs")) {
    return (
      <button
        type="button"
        data-drawer-target="docs-sidebar"
        data-drawer-toggle="docs-sidebar"
        aria-controls="docs-sidebar"
        className="py-2 ml-2 text-neutral-800 rounded cursor-pointer md:hidden hover:text-neutral-900 hover:bg-neutral-100 focus:bg-neutral-100  focus:ring-2 focus:ring-neutral-100    "
      >
        <HiBars3 aria-hidden="true" className="w-6 h-6" />
        <span className="sr-only">Toggle sidebar</span>
      </button>
    );
  } else {
    return null;
  }
}
