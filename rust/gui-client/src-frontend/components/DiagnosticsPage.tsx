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

            <SettingRow label="Log Files">
              <div className="flex items-center gap-1">
                <span className="mr-2 text-sm tabular-nums text-body">
                  {`${megabytes} MB`}
                </span>
                <button
                  aria-label="Export Logs"
                  className="icon-button"
                  onClick={exportLogs}
                  title="Export Logs"
                  type="button"
                >
                  <RemixIcon className="h-4 w-4" name="share-forward" />
                </button>
                <button
                  aria-label="Clear Logs"
                  className="icon-button -mr-1"
                  onClick={clearLogs}
                  title="Clear Logs"
                  type="button"
                >
                  <RemixIcon className="h-4 w-4" name="delete-bin" />
                </button>
              </div>
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
