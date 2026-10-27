import React from "react";

interface SettingRowProps extends React.PropsWithChildren {
  inputId?: string;
  label: string;
  // Text inputs and selects get a fixed-width column so they line up across rows.
  field?: boolean;
}

export default function SettingRow({
  children,
  field = false,
  inputId,
  label,
}: SettingRowProps) {
  return (
    <div className="flex min-h-10 items-center justify-between gap-6 px-4 py-1">
      <label
        className="block text-sm font-medium text-heading"
        htmlFor={inputId}
      >
        {label}
      </label>
      {field ? <div className="w-64 shrink-0">{children}</div> : children}
    </div>
  );
}
