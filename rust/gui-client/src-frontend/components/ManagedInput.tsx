import React, { InputHTMLAttributes, PropsWithChildren } from "react";

type ManagedTextInputProps = InputHTMLAttributes<HTMLInputElement> & {
  managed: boolean;
};

export function ManagedTextInput(props: ManagedTextInputProps) {
  const { managed, disabled, className = "", ...inputProps } = props;

  const input = (
    <input
      aria-disabled={managed || undefined}
      className={`form-input ${className}`}
      disabled={managed || disabled}
      {...inputProps}
    />
  );

  if (managed) {
    return <ManagedTooltip fullWidth>{input}</ManagedTooltip>;
  } else {
    return input;
  }
}

interface ManagedToggleSwitchProps {
  checked: boolean;
  id?: string;
  managed: boolean;
  name?: string;
  onChange: (checked: boolean) => void;
}

export function ManagedToggleSwitch(props: ManagedToggleSwitchProps) {
  const { checked, id, managed, name, onChange } = props;

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
        className={`toggle-thumb ${checked ? "translate-x-2.5" : ""}`}
      />
    </button>
  );

  if (managed) {
    return <ManagedTooltip>{toggle}</ManagedTooltip>;
  } else {
    return toggle;
  }
}

function ManagedTooltip(
  props: PropsWithChildren<{
    fullWidth?: boolean;
  }>
) {
  const { children, fullWidth = false } = props;

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
