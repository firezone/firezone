import React, { InputHTMLAttributes, SelectHTMLAttributes } from "react";
import RemixIcon from "./RemixIcon";

type ManagedTextInputProps = InputHTMLAttributes<HTMLInputElement> & {
  managed: boolean;
};

export function ManagedTextInput({
  disabled,
  managed,
  className = "",
  ...inputProps
}: ManagedTextInputProps) {
  const input = (
    <input
      aria-disabled={managed || undefined}
      className={`form-input ${className}`}
      disabled={managed || disabled}
      {...inputProps}
    />
  );

  if (!managed) {
    return input;
  }

  return <ManagedTooltip fullWidth>{input}</ManagedTooltip>;
}

type ManagedSelectProps = SelectHTMLAttributes<HTMLSelectElement> & {
  managed: boolean;
};

export function ManagedSelect({
  disabled,
  managed,
  className = "",
  ...selectProps
}: ManagedSelectProps) {
  // The native arrow sits flush against the right border, so draw our own with padding.
  const select = (
    <span className="relative flex w-full">
      <select
        aria-disabled={managed || undefined}
        className={`form-input appearance-none pr-9 ${className}`}
        disabled={managed || disabled}
        {...selectProps}
      />
      <RemixIcon
        className={`pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-subtle ${
          managed || disabled ? "opacity-40" : ""
        }`}
        name="arrow-down"
      />
    </span>
  );

  if (!managed) {
    return select;
  }

  return <ManagedTooltip fullWidth>{select}</ManagedTooltip>;
}

interface ManagedToggleSwitchProps {
  checked: boolean;
  id?: string;
  managed: boolean;
  name?: string;
  onChange: (checked: boolean) => void;
}

export function ManagedToggleSwitch({
  checked,
  id,
  managed,
  name,
  onChange,
}: ManagedToggleSwitchProps) {
  const toggle = (
    <button
      aria-checked={checked}
      aria-disabled={managed || undefined}
      className={`toggle ${
        checked ? "border-brand bg-brand" : "border-border-emphasis bg-raised"
      } ${managed ? "cursor-not-allowed opacity-40" : ""}`}
      disabled={managed}
      id={id}
      name={name}
      onClick={() => onChange(!checked)}
      role="switch"
      type="button"
    >
      <span
        aria-hidden="true"
        className={`toggle-thumb ${checked ? "translate-x-3.5" : ""}`}
      />
    </button>
  );

  if (!managed) {
    return toggle;
  }

  return <ManagedTooltip>{toggle}</ManagedTooltip>;
}

function ManagedTooltip({
  children,
  fullWidth = false,
}: React.PropsWithChildren<{ fullWidth?: boolean }>) {
  return (
    <span
      className={`group relative ${fullWidth ? "flex w-full" : "inline-flex"}`}
    >
      {children}
      <span className="managed-tooltip" role="tooltip">
        This setting is managed by your organisation.
      </span>
    </span>
  );
}
