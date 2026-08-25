import React from "react";
import {
  X509DetailSection,
  X509FieldValue,
  X509Status,
} from "../generated/bindings";
import RemixIcon from "./RemixIcon";

const CERTIFICATE_SECTION = "Certificate";

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

function presentField(
  section: X509DetailSection | undefined,
  label: string
): string | null {
  const value = section?.fields.find((field) => field.label === label)?.value;

  if (value === undefined || value === "Absent" || "Invalid" in value) {
    return null;
  }

  return value.Present;
}

function Warning({ warning }: { warning: string }) {
  return (
    <div className="mt-4 flex gap-2.5 rounded border border-warning/30 bg-warning-light p-3 text-sm text-warning">
      <RemixIcon className="mt-0.5 h-4 w-4" name="alert" />
      <p>{warning}</p>
    </div>
  );
}

function SummaryCard({
  certificate,
  warning,
}: {
  certificate: X509DetailSection | undefined;
  warning: string | null;
}) {
  const commonName = presentField(certificate, "Common Name");
  const subject = presentField(certificate, "Subject");
  const issuer = presentField(certificate, "Issuer");
  const notAfter = presentField(certificate, "Not After");
  const found = certificate !== undefined;

  return (
    <section className="panel p-4">
      <div className="flex gap-3">
        <RemixIcon className="h-8 w-8 text-subtle" name="certificate" />
        <div className="min-w-0">
          <h2 className="break-words text-base font-semibold tracking-tight text-heading">
            {found
              ? (commonName ?? subject ?? "Client certificate")
              : "No client certificate"}
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
          <p className="mt-2 text-xs text-subtle">
            {found
              ? "Firezone uses this certificate to identify this device."
              : "Firezone did not find a certificate to identify this device."}
          </p>
        </div>
      </div>
      {warning !== null && <Warning warning={warning} />}
    </section>
  );
}

function DetailSection({ section }: { section: X509DetailSection }) {
  return (
    <section className="panel p-4">
      {section.title !== CERTIFICATE_SECTION && (
        <h3 className="mb-3 font-medium text-heading">{section.title}</h3>
      )}
      <dl className="divide-y divide-border">
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
  );
}

export default function X509Page({ status }: { status: X509Status | null }) {
  return (
    <div className="page max-w-3xl space-y-4">
      {status === null ? (
        <div className="panel p-4 text-body">
          Reading the platform keystore…
        </div>
      ) : (
        <>
          <SummaryCard
            certificate={status.sections.find(
              (section) => section.title === CERTIFICATE_SECTION
            )}
            warning={status.warning}
          />
          {status.sections.map((section, sectionIndex) => (
            <DetailSection
              key={`${section.title}-${sectionIndex}`}
              section={section}
            />
          ))}
        </>
      )}
    </div>
  );
}
