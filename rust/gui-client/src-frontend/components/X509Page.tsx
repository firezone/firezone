import React from "react";
import { X509FieldValue, X509Status } from "../generated/bindings";
import RemixIcon from "./RemixIcon";

function FieldValue({ value }: { value: X509FieldValue }) {
  if (value === "Absent") {
    return <span className="text-subtle">Not present</span>;
  }

  if ("Invalid" in value) {
    return (
      <span className="flex gap-1.5 text-warning">
        <RemixIcon className="mt-0.5 h-3.5 w-3.5 shrink-0" name="alert" />
        {value.Invalid}
      </span>
    );
  }

  return <>{value.Present}</>;
}

export default function X509Page({ status }: { status: X509Status | null }) {
  return (
    <div className="page max-w-3xl space-y-4">
      <div>
        <h2 className="page-title">X.509 Device Identity</h2>
        <p className="page-description mt-1">
          Firezone can prove this device is enrolled with a certificate your
          administrator provisions. The private key stays inside the platform
          keystore and is never exported.
        </p>
      </div>

      {status === null ? (
        <div className="panel p-4 text-body">
          Reading the platform keystore…
        </div>
      ) : (
        <>
          {status.severity === "Warning" ? (
            <div className="flex gap-2.5 rounded border border-warning/30 bg-warning-light p-3 text-sm text-warning">
              <RemixIcon className="mt-0.5 h-4 w-4" name="alert" />
              <p>{status.summary}</p>
            </div>
          ) : (
            <p className="text-body">{status.summary}</p>
          )}
          {status.sections.map((section, sectionIndex) => (
            <section
              className="panel p-4"
              key={`${section.title}-${sectionIndex}`}
            >
              <h3 className="font-medium text-heading">{section.title}</h3>
              <dl className="mt-3 divide-y divide-border">
                {section.fields.map((field, fieldIndex) => (
                  <div
                    className="grid gap-1 py-2.5 first:pt-0 last:pb-0 sm:grid-cols-[12rem_minmax(0,1fr)]"
                    key={`${field.label}-${fieldIndex}`}
                  >
                    <dt className="text-xs text-subtle">{field.label}</dt>
                    <dd className="whitespace-pre-wrap break-all font-mono text-xs text-body">
                      <FieldValue value={field.value} />
                    </dd>
                  </div>
                ))}
              </dl>
            </section>
          ))}
        </>
      )}
    </div>
  );
}
