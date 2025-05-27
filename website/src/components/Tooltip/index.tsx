"use client";

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
      <span className="underline underline-offset-4 decoration-neutral-400 decoration-dotted cursor-help">
        {children}
      </span>
    </FlowbiteTooltip>
  );
}
