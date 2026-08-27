import React from "react";
import {
  X509DetailSection,
  X509FieldProblem,
  X509Package,
  X509Problem,
  X509Status,
  X509UnreadableStore,
  X509UnusableCause,
  X509ValidationError,
} from "../generated/bindings";
import RemixIcon from "./RemixIcon";

const CERTIFICATE_SECTION = "Certificate";

const VALIDATION_ERROR_TEXT: Record<X509ValidationError, string> = {
  Empty: "empty",
  TooLong: "longer than 255 characters",
  NotAnEmailAddress: "not a valid email address",
  NotAUuid: "not a UUID",
  Ambiguous: "more than one value was given",
  PlaceholderIdentifier: "a placeholder identifier",
  UnknownAttribute: "not an attribute we understand",
};

const MISSING_PACKAGE_TEXT: Record<X509Package, string> = {
  P11Kit:
    "No PKCS#11 module is registered, so no X.509 client identity certificate can be found. Firezone reads certificates through PKCS#11 modules registered with p11-kit. See https://www.firezone.dev/kb/install/linux#device-certificates for what to install.",
};

function problemText(problem: X509Problem): string {
  if (problem === "UnreadablePkcs11Keystore") {
    return "The PKCS#11 keystore cannot be read, so no X.509 client identity certificate can be found. See https://www.firezone.dev/kb/install/linux#device-certificates for what the keystore needs installed and running.";
  }

  if (problem === "UnreadableKeystore") {
    return "The platform keystore could not be read, so no X.509 client identity certificate can be found.";
  }

  if (problem === "UnsupportedPlatform") {
    return "This platform has no X.509 keystore backend.";
  }

  if ("NoWindowsCertificate" in problem) {
    const { subject_cn } = problem.NoWindowsCertificate;

    return `No X.509 certificate with subject CN '${subject_cn}' is in the Windows certificate stores.`;
  }

  if ("UnreadableWindowsStores" in problem) {
    const { stores } = problem.UnreadableWindowsStores;

    return `Some Windows certificate stores could not be read: ${storeText(stores)}`;
  }

  if ("NoPkcs11Certificate" in problem) {
    const { subject_cn } = problem.NoPkcs11Certificate;

    return `No PKCS#11 token holds an X.509 certificate with subject CN '${subject_cn}'.`;
  }

  return MISSING_PACKAGE_TEXT[problem.MissingPackage.package];
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

function storeText(stores: X509UnreadableStore[]): string {
  return stores.map(({ store, error }) => `${store}: ${error}`).join("; ");
}

function FieldValue({ value }: { value: string | null }) {
  if (value === null) {
    return <span className="text-subtle">Not present</span>;
  }

  return <>{value}</>;
}

// Reads underneath the value it belongs to, the way a form shows an error on its input.
function FieldProblem({ problem }: { problem: X509FieldProblem }) {
  if ("Invalid" in problem) {
    return (
      <Note tone="text-warning">{VALIDATION_ERROR_TEXT[problem.Invalid]}</Note>
    );
  }

  if ("Unusable" in problem) {
    return <Note tone="text-warning">{causeText(problem.Unusable)}</Note>;
  }

  return <Note tone="text-warning">{problem.Unreadable}</Note>;
}

function Note({ tone, children }: { tone: string; children: React.ReactNode }) {
  return (
    <span className={`mt-1 flex gap-1.5 font-sans ${tone}`}>
      <RemixIcon className="mt-0.5 h-3.5 w-3.5 shrink-0" name="alert" />
      {children}
    </span>
  );
}

function presentField(
  section: X509DetailSection | undefined,
  label: string
): string | null {
  return section?.fields.find((field) => field.label === label)?.value ?? null;
}

function Warning({ problem }: { problem: X509Problem }) {
  return (
    <div className="mt-4 flex gap-2.5 rounded border border-warning/30 bg-warning-light p-3 text-sm text-warning">
      <RemixIcon className="mt-0.5 h-4 w-4 shrink-0" name="alert" />
      {/* A knowledge-base URL is one long word, and a flex item is by default as
          wide as its longest word. Left alone it makes the box wider than the
          page and takes the right-hand border off the window with it. */}
      <p className="min-w-0 break-words">{problemText(problem)}</p>
    </div>
  );
}

// What the card says Firezone does with the certificate the keystore found, if it found one,
// and the mark that leads it.
//
function SummaryCard({ status }: { status: X509Status }) {
  const certificate = status.sections.find(
    (section) => section.title === CERTIFICATE_SECTION
  );
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
        </div>
      </div>
      {!found && (
        <p className="mt-2 text-xs text-subtle">
          Firezone did not find a certificate to identify this device.
        </p>
      )}
      {status.problems.map((problem, problemIndex) => (
        <Warning key={problemIndex} problem={problem} />
      ))}
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

export default function X509Page({ status }: { status: X509Status | null }) {
  return (
    <div className="page max-w-3xl space-y-4">
      {status === null ? (
        <div className="panel p-4 text-body">
          Reading the platform keystore…
        </div>
      ) : (
        <>
          <SummaryCard status={status} />
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
