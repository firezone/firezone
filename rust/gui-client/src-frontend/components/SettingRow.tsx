import React from "react";

interface SettingRowProps extends React.PropsWithChildren {
  inputId?: string;
  label: string;
  // Text inputs and selects get a fixed-width column so they line up across rows.
  field?: boolean;
  error?: string;
  errorId?: string;
}

export default function SettingRow({
  children,
  field = false,
  inputId,
  label,
  error,
  errorId,
}: SettingRowProps) {
  return (
    <div className="flex min-h-10 flex-col justify-center px-4 py-1">
      <div className="flex items-center justify-between gap-6">
        <label
          className="block text-sm font-medium text-heading"
          htmlFor={inputId}
        >
          {label}
        </label>
        {field ? <div className="w-64 shrink-0">{children}</div> : children}
      </div>
      {error && (
        <p className="ml-auto w-64 pb-1 pt-1 text-xs text-error" id={errorId}>
          {error}
        </p>
      )}
    </div>
  );
}
