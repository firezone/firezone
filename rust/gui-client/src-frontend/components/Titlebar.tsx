import { XMarkIcon } from "@heroicons/react/16/solid";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { Navbar } from "flowbite-react";
import React from "react";

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
    <div onMouseDown={handleMouseDown} className="select-none">
      <Navbar
        clearTheme={{
          root: {
            base: true,
          },
        }}
        theme={{
          root: {
            base: "py-1 px-2 bg-gray-100 flex flex-row space-between",
            inner: {
              base: "max-w-full",
            },
          },
        }}
      >
        <h2 className="text-xl font-semibold">{title}</h2>
        <div
          className="justify-self-end"
          onMouseDown={(e) => e.stopPropagation()}
          onClick={() => getCurrentWindow().close()}
        >
          <XMarkIcon className="h-6 p-1 rounded-full hover:text-gray-700 hover:bg-gray-200" />
        </div>
      </Navbar>
    </div>
  );
}
