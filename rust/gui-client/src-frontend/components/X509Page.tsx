import React from "react";
import {
  X509Certificate,
  X509DetailField,
  X509ValidationError,
} from "../generated/bindings";
import RemixIcon from "./RemixIcon";

const VALIDATION_ERROR_TEXT: Record<X509ValidationError, string> = {
  Empty: "empty",
  TooLong: "longer than 255 characters",
  Ambiguous: "more than one value was given",
  PlaceholderIdentifier: "a placeholder identifier",
  UnknownAttribute: "not an attribute we understand",
  NotYetValid: "not yet valid",
  Expired: "expired",
  MissingClientAuthEku: "required for mutual TLS",
  DigitalSignatureNotAllowed: "required to sign the TLS handshake",
};

function FieldValue({ value }: { value: string | null }) {
  if (value === null) {
    return <span className="text-subtle">Not present</span>;
  }

  return <>{value}</>;
}

// Reads underneath the value it belongs to, the way a form shows an error on its input.
function FieldProblem({ problem }: { problem: X509ValidationError }) {
  return (
    <span className="mt-1 flex gap-1.5 font-sans text-warning">
      <RemixIcon className="mt-0.5 h-3.5 w-3.5 shrink-0" name="alert" />
      {VALIDATION_ERROR_TEXT[problem]}
    </span>
  );
}

function presentField(fields: X509DetailField[], label: string): string | null {
  return fields.find((field) => field.label === label)?.value ?? null;
}

// What the card says Firezone does with the certificate, and the mark that leads it.
function SummaryCard({ certificate }: { certificate: X509Certificate }) {
  const fields = certificate.fields;
  const commonName = presentField(fields, "Common Name");
  const subject = presentField(fields, "Subject");
  const issuer = presentField(fields, "Issuer");
  const notAfter = presentField(fields, "Not After");

  return (
    <section className="panel p-4">
      <div className="flex gap-3">
        <RemixIcon className="h-8 w-8 text-subtle" name="certificate" />
        <div className="min-w-0">
          <h2 className="break-words text-base font-semibold tracking-tight text-heading">
            {commonName ?? subject ?? "Client certificate"}
          </h2>
          {issuer !== null && (
            <p className="mt-0.5 break-words text-sm text-body">
              Issued by {issuer}
            </p>
          )}
          {notAfter !== null && (
            <p className="mt-0.5 break-words text-sm text-body">
              Valid until {notAfter}
            </p>
          )}
        </div>
      </div>
    </section>
  );
}

function DetailFields({ fields }: { fields: X509DetailField[] }) {
  return (
    <section className="panel p-4">
      <dl className="divide-y divide-border">
        {fields.map((field, fieldIndex) => (
          <div
            className="grid gap-1 py-2.5 first:pt-0 last:pb-0 sm:grid-cols-[12rem_minmax(0,1fr)]"
            key={`${field.label}-${fieldIndex}`}
          >
            <dt className="text-xs text-subtle">{field.label}</dt>
            <dd className="whitespace-pre-wrap break-all font-mono text-xs text-body">
              <FieldValue value={field.value} />
              {field.problem !== null && (
                <FieldProblem problem={field.problem} />
              )}
            </dd>
          </div>
        ))}
      </dl>
    </section>
  );
}

export default function X509Page({
  certificate,
}: {
  certificate: X509Certificate;
}) {
  return (
    <div className="page max-w-3xl space-y-4">
      <SummaryCard certificate={certificate} />
      <DetailFields fields={certificate.fields} />
    </div>
  );
}
