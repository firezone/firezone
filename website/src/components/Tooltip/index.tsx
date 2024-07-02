import type { CustomFlowbiteTheme } from "flowbite-react";
import { Tooltip as FlowbiteTooltip } from "flowbite-react";

const customTheme: CustomFlowbiteTheme["tooltip"] = {
  base: "text-wrap absolute z-10 invisible inline-block px-3 py-2 text-xs font-medium text-white transition-opacity duration-100 bg-neutral-900 rounded shadow-sm opacity-90 tooltip",
};

export default function Tooltip({
  content,
  children,
}: {
  content: string;
  children: React.ReactNode;
}) {
  return (
    <FlowbiteTooltip theme={customTheme} content={content}>
      {children}
    </FlowbiteTooltip>
  );
}
