import React, { useCallback, useEffect, useState } from "react";
import { commands, X509Status } from "../generated/bindings";
import Button from "./Button";
import RemixIcon from "./RemixIcon";

export default function X509SettingsPage() {
  const [status, setStatus] = useState<X509Status | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await commands.x509Status();
      if (result.status === "ok") {
        setStatus(result.data);
      } else {
        setStatus(null);
        setError(result.error);
      }
    } catch (error) {
      setStatus(null);
      setError(error instanceof Error ? error.message : String(error));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  return (
    <div className="page max-w-3xl space-y-4">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="page-title">X.509 Identity</h2>
          <p className="page-description mt-1">
            Firezone uses a managed certificate for mutual TLS and, when Actor
            Email and Account ID attributes are present, user authentication.
            Private-key bytes remain in the Windows certificate provider or
            Linux PKCS#11 token.
          </p>
        </div>
        <Button disabled={loading} onClick={() => void refresh()}>
          Refresh
        </Button>
      </div>

      {loading ? (
        <div className="panel p-4 text-body">Reading X.509 identity…</div>
      ) : error ? (
        <div className="rounded border border-warning/30 bg-warning-light p-4 text-warning">
          <div className="flex items-start gap-2.5">
            <RemixIcon className="mt-0.5 h-4 w-4" name="alert" />
            <div>
              <p className="font-medium">Unable to read the X.509 identity</p>
              <p className="mt-1 whitespace-pre-wrap break-words font-mono text-xs">
                {error}
              </p>
              <p className="mt-2 text-sm">
                Contact your administrator for support.
              </p>
            </div>
          </div>
        </div>
      ) : status ? (
        <>
          <p className="text-body">{status.summary}</p>
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
                      {field.value}
                    </dd>
                  </div>
                ))}
              </dl>
            </section>
          ))}
        </>
      ) : null}
    </div>
  );
}
