import React, { useEffect, useId, useState } from "react";
import { FileCount, LogFilterViewModel } from "../generated/bindings";
import Button from "./Button";
import { ManagedTextInput } from "./ManagedInput";
import RemixIcon from "./RemixIcon";
import SettingRow from "./SettingRow";

interface DiagnosticsPageProps {
  logCount: FileCount | null;
  logFilter: LogFilterViewModel | null;
  exportLogs: () => void;
  clearLogs: () => void;
  saveLogFilter: (logFilter: string) => void;
  resetLogFilter: () => void;
}

const defaultLogFilter: LogFilterViewModel = {
  log_filter: "",
  log_filter_is_managed: false,
};

export default function Diagnostics({
  logCount,
  logFilter,
  exportLogs,
  clearLogs,
  saveLogFilter,
  resetLogFilter,
}: DiagnosticsPageProps) {
  const bytes = logCount?.bytes ?? 0;
  const files = logCount?.files ?? 0;
  const megabytes = Math.round((bytes / 1_000_000) * 10) / 10;

  const [localLogFilter, setLocalLogFilter] = useState<LogFilterViewModel>(
    logFilter ?? defaultLogFilter
  );

  useEffect(() => {
    setLocalLogFilter(logFilter ?? defaultLogFilter);
  }, [logFilter]);

  const logFilterInputId = useId();

  return (
    <div className="page">
      <form
        className="max-w-xl space-y-3"
        onSubmit={(event) => {
          event.preventDefault();
          saveLogFilter(localLogFilter.log_filter);
        }}
      >
        <section>
          <h2 className="form-label">Logs</h2>
          <div className="panel divide-y divide-border">
            <div className="flex min-h-10 items-center justify-between gap-6 px-4 py-3">
              <div>
                <p className="text-sm font-medium text-heading">
                  Log directory
                </p>
                <p className="mt-0.5 font-mono text-xs tabular-nums text-subtle">
                  {`${files} files, ${megabytes} MB`}
                </p>
              </div>
              <div className="flex gap-2">
                <Button onClick={exportLogs} type="button">
                  <RemixIcon className="h-3.5 w-3.5" name="share-forward" />
                  Export Logs
                </Button>
                <Button onClick={clearLogs} type="button">
                  <RemixIcon className="h-3.5 w-3.5" name="delete-bin" />
                  Clear Logs
                </Button>
              </div>
            </div>

            <SettingRow field inputId={logFilterInputId} label="Log Filter">
              <ManagedTextInput
                className="h-8 py-1 font-mono text-xs"
                id={logFilterInputId}
                managed={localLogFilter.log_filter_is_managed}
                name="log_filter"
                onChange={(event) =>
                  setLocalLogFilter({
                    ...localLogFilter,
                    log_filter: event.target.value,
                  })
                }
                required
                value={localLogFilter.log_filter}
              />
            </SettingRow>
          </div>
        </section>

        <div className="flex justify-end gap-2 border-t border-border pt-3">
          <Button
            disabled={localLogFilter.log_filter_is_managed}
            onClick={resetLogFilter}
            type="reset"
          >
            Reset to Default
          </Button>
          <Button
            disabled={localLogFilter.log_filter_is_managed}
            type="submit"
            variant="primary"
          >
            Apply
          </Button>
        </div>
      </form>
    </div>
  );
}
