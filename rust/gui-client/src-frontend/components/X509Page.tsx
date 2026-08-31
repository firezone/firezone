import React from "react";
import {
  X509Certificate,
  X509DetailField,
  X509Error,
  X509UnusableCause,
  X509ValidationError,
} from "../generated/bindings";
import RemixIcon from "./RemixIcon";

const VALIDATION_ERROR_TEXT: Record<X509ValidationError, string> = {
  Empty: "empty",
  TooLong: "longer than 255 characters",
  NotAnEmailAddress: "not a valid email address",
  NotAUuid: "not a UUID",
  Ambiguous: "more than one value was given",
  PlaceholderIdentifier: "a placeholder identifier",
  UnknownAttribute: "not an attribute we understand",
  NotYetValid: "not yet valid",
  Expired: "expired",
  MissingClientAuthEku: "required for mutual TLS",
  DigitalSignatureNotAllowed: "required to sign the TLS handshake",
};

function errorText(error: X509Error): string {
  if (error === "MissingP11Kit") {
    return "No PKCS#11 module is registered, so no X.509 client identity certificate can be found. Firezone reads certificates through PKCS#11 modules registered with p11-kit. See https://www.firezone.dev/kb/reference/device-certificates for what to install.";
  }

  if ("UnreadableStore" in error) {
    const { store, error: cause } = error.UnreadableStore;

    return `The Windows certificate store ${store} could not be read: ${cause}`;
  }

  if ("UnreadablePkcs11Keystore" in error) {
    const { modules } = error.UnreadablePkcs11Keystore;

    return `The PKCS#11 keystore cannot be read, so no X.509 client identity certificate can be found: ${modules.join(
      "; "
    )}. See https://www.firezone.dev/kb/reference/device-certificates for what the keystore needs installed and running.`;
  }

  if ("NoUsableIdentity" in error) {
    const { causes } = error.NoUsableIdentity;

    return `The keystore holds no usable Firezone client identity: ${causes
      .map(causeText)
      .join("; ")}`;
  }

  if ("IdentityUnavailable" in error) {
    return error.IdentityUnavailable.message;
  }

  return `The platform keystore could not be read: ${error.UnreadableKeystore.message}`;
}

function causeText(cause: X509UnusableCause): string {
  if (cause === "KeyMissing") {
    return "the keystore holds no private key for this certificate";
  }

  if (cause === "UnsupportedKeyAlgorithm") {
    return "we cannot sign with this certificate's key algorithm";
  }

  return `the keystore would not hand over the private key: ${cause.KeyRefused.error}`;
}

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

function Warning({ error }: { error: X509Error }) {
  return (
    <div className="mt-4 flex gap-2.5 rounded border border-warning/30 bg-warning-light p-3 text-sm text-warning">
      <RemixIcon className="mt-0.5 h-4 w-4 shrink-0" name="alert" />
      {/* A knowledge-base URL is one long word, and a flex item is by default as
          wide as its longest word. Left alone it makes the box wider than the
          page and takes the right-hand border off the window with it. */}
      <p className="min-w-0 break-words">{errorText(error)}</p>
    </div>
  );
}

// What the card says Firezone does with the certificate the keystore holds, if it holds one,
// and the mark that leads it.
function SummaryCard({ certificate }: { certificate: X509Certificate }) {
  const loaded = typeof certificate === "object" && "Loaded" in certificate;
  const fields = loaded ? certificate.Loaded.fields : [];
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
            {loaded
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
        </div>
      </div>
      {certificate === "Absent" && (
        <p className="mt-2 text-xs text-subtle">
          Firezone did not find a certificate to identify this device.
        </p>
      )}
      {typeof certificate === "object" && "Error" in certificate && (
        <Warning error={certificate.Error} />
      )}
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
  certificate: X509Certificate | null;
}) {
  return (
    <div className="page max-w-3xl space-y-4">
      {certificate === null ? (
        <div className="panel p-4 text-body">
          Reading the platform keystore…
        </div>
      ) : (
        <>
          <SummaryCard certificate={certificate} />
          {typeof certificate === "object" && "Loaded" in certificate && (
            <DetailFields fields={certificate.Loaded.fields} />
          )}
        </>
      )}
    </div>
  );
}
