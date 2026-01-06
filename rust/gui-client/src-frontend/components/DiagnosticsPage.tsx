import React from "react";
import { ShareIcon, TrashIcon } from "@heroicons/react/16/solid";
import { Button } from "flowbite-react";
import { FileCount } from "../generated/bindings";

interface DiagnosticsPageProps {
  logCount: FileCount | null;
  exportLogs: () => void;
  clearLogs: () => void;
}

export default function Diagnostics({
  logCount,
  exportLogs,
  clearLogs,
}: DiagnosticsPageProps) {
  const bytes = logCount?.bytes ?? 0;
  const files = logCount?.files ?? 0;

  const megabytes = Math.round(Number(bytes / 100000)) / 10;

  return (
    <div className="container mx-auto p-4">
      <div className="p-4 rounded-lg">
        <div className="mt-8 flex justify-center">
          <p className="mr-1">Log directory size:</p>
          <p>{`${files} files, ${megabytes} MB`}</p>
        </div>

        <div className="mt-8 flex justify-center gap-4">
          <Button onClick={exportLogs} color="alternative">
            <ShareIcon className="mr-2 h-5 w-5" />
            Export Logs
          </Button>

          <Button onClick={clearLogs} color="alternative">
            <TrashIcon className="mr-2 h-5 w-5" />
            Clear Logs
          </Button>
        </div>
      </div>
    </div>
  );
}
