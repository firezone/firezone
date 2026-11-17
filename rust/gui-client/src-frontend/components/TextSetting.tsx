import React, { useEffect, useId, useRef, useState } from "react";
import { ManagedTextInput } from "./ManagedInput";
import RemixIcon from "./RemixIcon";
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
  const [savedAt, setSavedAt] = useState<number | null>(null);

  const updateDraft = (draft: string | null) => {
    setDraft(draft);
    onDraftChange?.(draft);
  };

  // The saved value comes back after a save, possibly normalised, and replaces the draft.
  useEffect(() => {
    if (lastSaved.current !== null) {
      setSavedAt(Date.now());
    }
    updateDraft(null);
    setError(null);
    lastSaved.current = null;
  }, [value]);

  useEffect(() => {
    if (savedAt === null) {
      return;
    }

    const timeout = setTimeout(() => setSavedAt(null), 2000);
    return () => clearTimeout(timeout);
  }, [savedAt]);

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

  const isDraft = draft !== null && draft !== value;
  const isSaved = savedAt !== null && !isDraft;

  return (
    <SettingRow
      error={error ?? undefined}
      errorId={errorId}
      field
      inputId={inputId}
      label={label}
      managed={managed}
    >
      <span className="relative flex w-full">
        <ManagedTextInput
          aria-describedby={error ? errorId : undefined}
          aria-invalid={error ? true : undefined}
          className={`pr-9 ${className}`}
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
        <span
          aria-hidden="true"
          className={`pointer-events-none absolute right-4 top-1/2 h-2 w-2 -translate-y-1/2 rounded-full bg-brand transition-opacity duration-300 ${
            isDraft ? "opacity-100" : "opacity-0"
          }`}
        />
        <RemixIcon
          className={`pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 text-success transition-opacity duration-300 ${
            isSaved ? "opacity-100" : "opacity-0"
          }`}
          name="check"
        />
        <span aria-live="polite" className="sr-only">
          {isSaved ? "Saved" : ""}
        </span>
      </span>
    </SettingRow>
  );
}
