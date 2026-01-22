import { ClipboardWithIcon } from "flowbite-react";
import type { ClipboardWithIconTheme } from "flowbite-react";

const clipboardTheme: ClipboardWithIconTheme = {
  base: "absolute end-3 top-4 inline-flex items-center justify-center rounded-sm p-2 text-neutral-500 transition transform duration-200 hover:text-neutral-800 hover:bg-neutral-50",
  icon: {
    defaultIcon: "h-4 w-4",
    successIcon: "h-4 w-4 text-accent-500",
  },
};

export default function Clipboard({ valueToCopy }: { valueToCopy: string }) {
  return <ClipboardWithIcon theme={clipboardTheme} valueToCopy={valueToCopy} />;
}
