import { Clipboard as FlowbiteClipboard } from "flowbite-react";
import type { CustomFlowbiteTheme } from "flowbite-react";

const clipboardTheme: CustomFlowbiteTheme["clipboard"] = {
  withIcon: {
    base: "absolute end-2 top-2 inline-flex items-center justify-center rounded p-1.5 text-neutral-500 transition transform duration-200 hover:text-neutral-800 hover:bg-neutral-50",
    icon: {
      defaultIcon: "h-4 w-4",
      successIcon: "h-4 w-4 text-accent-500",
    },
  },
};

export default function Clipboard({ valueToCopy }: { valueToCopy: string }) {
  return (
    <FlowbiteClipboard.WithIcon
      theme={clipboardTheme?.withIcon}
      valueToCopy={valueToCopy}
    />
  );
}
