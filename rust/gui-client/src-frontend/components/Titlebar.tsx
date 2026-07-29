import { getCurrentWindow } from "@tauri-apps/api/window";
import React from "react";
import RemixIcon from "./RemixIcon";

export interface TitlebarProps {
  title?: string;
}

export default function Titlebar({ title }: TitlebarProps) {
  const handleMouseDown = (e: React.MouseEvent) => {
    if (e.buttons === 1) {
      getCurrentWindow().startDragging();
    }
  };

  return (
    <header
      onMouseDown={handleMouseDown}
      className="flex h-14 shrink-0 select-none items-center justify-between border-b border-border bg-surface px-4"
    >
      <h1 className="truncate text-sm font-semibold text-heading">{title}</h1>
      <button
        className="icon-button -mr-1"
        onMouseDown={(e) => e.stopPropagation()}
        onClick={() => getCurrentWindow().close()}
        aria-label="Close window"
        title="Close"
        type="button"
      >
        <RemixIcon className="h-4 w-4" name="close" />
      </button>
    </header>
  );
}
