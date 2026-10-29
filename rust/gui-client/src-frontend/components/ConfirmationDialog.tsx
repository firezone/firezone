import React, { useEffect, useId, useRef } from "react";
import Button from "./Button";

interface ConfirmationDialogProps {
  question: string;
  confirmLabel: string;
  onConfirm: () => void;
  onCancel: () => void;
}

export default function ConfirmationDialog({
  question,
  confirmLabel,
  onConfirm,
  onCancel,
}: ConfirmationDialogProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const questionId = useId();

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    dialog.showModal();
    return () => dialog.close();
  }, []);

  const finish = (action: () => void) => {
    // Close before callbacks unmount the dialog so the browser can restore focus.
    dialogRef.current?.close();
    action();
  };

  return (
    <dialog
      aria-labelledby={questionId}
      className="m-auto w-96 max-w-[calc(100%-2rem)] rounded-lg border border-border-strong bg-elevated p-5 text-heading shadow-xl backdrop:bg-black/40"
      onCancel={(event) => {
        event.preventDefault();
        finish(onCancel);
      }}
      ref={dialogRef}
    >
      <h2 className="text-base font-semibold" id={questionId}>
        {question}
      </h2>
      <div className="mt-5 flex justify-end gap-2">
        <Button autoFocus onClick={() => finish(onCancel)} type="button">
          Cancel
        </Button>
        <Button
          onClick={() => finish(onConfirm)}
          type="button"
          variant="danger"
        >
          {confirmLabel}
        </Button>
      </div>
    </dialog>
  );
}
