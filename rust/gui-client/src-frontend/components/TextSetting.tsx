import React, { useEffect, useId, useRef, useState } from "react";
import { ManagedTextInput } from "./ManagedInput";
import SettingRow from "./SettingRow";

interface TextSettingProps {
  label: string;
  name: string;
  managed: boolean;
  value: string;
  // Returns what is wrong with `value`, or `null` to save it.
  validate?: (value: string) => string | null;
  // May resolve to a string saying why the value was rejected, which shows like a validation error.
  save: (value: string) => unknown;
  // Called with what the field shows while it differs from `value`, `null` once it does not.
  onDraftChange?: (draft: string | null) => void;
  className?: string;
}

// A text field that saves on Enter and on blur, and reverts on Escape.
export default function TextSetting({
  label,
  name,
  managed,
  value,
  validate = () => null,
  save,
  onDraftChange,
  className = "",
}: TextSettingProps) {
  const inputId = useId();
  const errorId = useId();
  const [draft, setDraft] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const lastSaved = useRef<string | null>(null);

  const updateDraft = (draft: string | null) => {
    setDraft(draft);
    onDraftChange?.(draft);
  };

  // The saved value comes back after a save, possibly normalised, and replaces the draft.
  useEffect(() => {
    updateDraft(null);
    setError(null);
    lastSaved.current = null;
  }, [value]);

  const commit = () => {
    if (draft === null || draft === value || draft === lastSaved.current) {
      return;
    }

    const problem = validate(draft);
    setError(problem);
    if (problem !== null) {
      return;
    }

    lastSaved.current = draft;
    void Promise.resolve(save(draft)).then((rejection) => {
      if (typeof rejection === "string" && lastSaved.current === draft) {
        lastSaved.current = null;
        setError(rejection);
      }
    });
  };

  return (
    <SettingRow
      error={error ?? undefined}
      errorId={errorId}
      field
      inputId={inputId}
      label={label}
    >
      <ManagedTextInput
        aria-describedby={error ? errorId : undefined}
        aria-invalid={error ? true : undefined}
        className={className}
        id={inputId}
        managed={managed}
        name={name}
        onBlur={commit}
        onChange={(event) => {
          updateDraft(event.target.value);
          setError(null);
        }}
        onKeyDown={(event) => {
          if (event.key === "Enter") {
            commit();
          } else if (event.key === "Escape") {
            updateDraft(null);
            setError(null);
          }
        }}
        value={draft ?? value}
      />
    </SettingRow>
  );
}
