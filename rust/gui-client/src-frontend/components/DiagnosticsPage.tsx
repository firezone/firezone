import React from "react";
import { FileCount, LogFilterViewModel, Result } from "../generated/bindings";
import RemixIcon from "./RemixIcon";
import SettingRow from "./SettingRow";
import { ManagedSettingsNotice } from "./ManagedInput";
import TextSetting from "./TextSetting";

interface DiagnosticsPageProps {
  logCount: FileCount | null;
  logFilter: LogFilterViewModel | null;
  exportLogs: () => void;
  clearLogs: () => void;
  saveLogFilter: (logFilter: string) => Promise<Result<null, string>>;
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
}: DiagnosticsPageProps) {
  const bytes = logCount?.bytes ?? 0;
  const megabytes = Math.round((bytes / 1_000_000) * 10) / 10;

  const saved = logFilter ?? defaultLogFilter;

  return (
    <div className="page">
      <div className="space-y-3">
        <section>
          <h2 className="form-label">Logs</h2>
          <div className="panel divide-y divide-border">
            <TextSetting
              className="font-mono text-xs"
              label="Log Filter"
              managed={saved.log_filter_is_managed}
              name="log_filter"
              save={async (filter) => {
                const result = await saveLogFilter(filter);
                return result.status === "error" ? result.error : null;
              }}
              value={saved.log_filter}
            />

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
          {saved.log_filter_is_managed && <ManagedSettingsNotice />}
        </section>
      </div>
    </div>
  );
}
