import React from "react";
import RemixIcon from "./RemixIcon";

interface SettingRowProps extends React.PropsWithChildren {
  inputId?: string;
  label: string;
  managed?: boolean;
  // Controls share a fixed-width column so they line up across rows.
  field?: boolean;
  error?: string;
  errorId?: string;
  // Rows that pass it show and announce a checkmark while it is true.
  saved?: boolean;
}

export default function SettingRow({
  children,
  field = false,
  inputId,
  label,
  managed = false,
  error,
  errorId,
  saved,
}: SettingRowProps) {
  return (
    <div className="flex min-h-10 flex-col justify-center pl-4 pr-2 py-2">
      <div className="flex items-center justify-between gap-6">
        <label
          className="flex items-center gap-1.5 text-sm font-medium text-heading"
          htmlFor={inputId}
        >
          {label}
          {managed && (
            <RemixIcon className="h-3.5 w-3.5 text-subtle" name="lock" />
          )}
          {saved !== undefined && (
            <RemixIcon
              className={`h-3.5 w-3.5 text-success transition-opacity duration-300 ${
                saved ? "opacity-100" : "opacity-0"
              }`}
              name="check"
            />
          )}
        </label>
        {saved !== undefined && (
          <span aria-live="polite" className="sr-only">
            {saved ? "Saved" : ""}
          </span>
        )}
        {field ? (
          <div className="flex h-9 w-64 shrink-0 items-center justify-end">
            {children}
          </div>
        ) : (
          children
        )}
      </div>
      {error && (
        <p className="ml-auto w-64 pb-1 pt-1 text-xs text-error" id={errorId}>
          {error}
        </p>
      )}
    </div>
  );
}
