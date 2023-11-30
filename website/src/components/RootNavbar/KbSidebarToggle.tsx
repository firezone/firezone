import { usePathname } from "next/navigation";
import { HiBars3 } from "react-icons/hi2";

export default function KbSidebarToggle() {
  const p = usePathname() || "";

  if (p.startsWith("/kb")) {
    return (
      <button
        type="button"
        data-drawer-target="kb-sidebar"
        data-drawer-toggle="kb-sidebar"
        aria-controls="kb-sidebar"
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
