import React from "react";
import { FileCount } from "../generated/bindings";
import Button from "./Button";
import RemixIcon from "./RemixIcon";

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
  const megabytes = Math.round((bytes / 1_000_000) * 10) / 10;

  return (
    <div className="page">
      <div className="panel max-w-xl p-4">
        <div className="mt-8 flex justify-center text-sm text-body">
          <div className="flex items-center gap-2.5">
            <RemixIcon className="h-4 w-4 text-subtle" name="database" />
            <p className="mr-1">Log directory size:</p>
            <p className="font-mono tabular-nums">
              {`${files} files, ${megabytes} MB`}
            </p>
          </div>
        </div>

        <div className="mt-8 flex justify-center gap-4">
          <Button onClick={exportLogs}>
            <RemixIcon className="h-3.5 w-3.5" name="share-forward" />
            Export Logs
          </Button>
          <Button onClick={clearLogs}>
            <RemixIcon className="h-3.5 w-3.5" name="delete-bin" />
            Clear Logs
          </Button>
        </div>
      </div>
    </div>
  );
}
