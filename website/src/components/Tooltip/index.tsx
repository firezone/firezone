"use client";

import type { CustomFlowbiteTheme } from "flowbite-react";
import { Tooltip as FlowbiteTooltip } from "flowbite-react";

export default function Tooltip({
  content,
  children,
}: {
  content: string;
  children: React.ReactNode;
}) {
  return (
    <FlowbiteTooltip content={content}>
      <span className="underline decoration-dotted cursor-help">
        {children}
      </span>
    </FlowbiteTooltip>
  );
}
