"use client";

import { useEffect, useId, useState } from "react";
import type { Mermaid as MermaidApi } from "mermaid";

let mermaidPromise: Promise<MermaidApi> | null = null;

function getMermaid(): Promise<MermaidApi> {
  if (!mermaidPromise) {
    mermaidPromise = import("mermaid").then(({ default: m }) => {
      m.initialize({
        startOnLoad: false,
        theme: "default",
        securityLevel: "strict",
        fontFamily: "inherit",
      });
      return m;
    });
  }
  return mermaidPromise;
}

type Rendered = { chart: string; svg: string };
type ErrorState = { chart: string; message: string };

export default function Mermaid({ chart }: { chart: string }) {
  const reactId = useId().replace(/[^a-zA-Z0-9]/g, "");
  const [rendered, setRendered] = useState<Rendered | null>(null);
  const [error, setError] = useState<ErrorState | null>(null);

  useEffect(() => {
    let cancelled = false;
    getMermaid()
      .then((mermaid) => mermaid.render(`mermaid-${reactId}`, chart.trim()))
      .then(({ svg }) => {
        if (!cancelled) setRendered({ chart, svg });
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          setError({
            chart,
            message: err instanceof Error ? err.message : String(err),
          });
        }
      });

    return () => {
      cancelled = true;
    };
  }, [chart, reactId]);

  if (error && error.chart === chart) {
    return (
      <pre className="my-6 overflow-auto rounded border border-red-300 bg-red-50 p-4 text-sm text-red-800">
        Mermaid error: {error.message}
        {"\n\n"}
        {chart}
      </pre>
    );
  }

  if (!rendered || rendered.chart !== chart) {
    return (
      <div className="my-6 flex justify-center text-sm text-neutral-500">
        Loading diagram…
      </div>
    );
  }

  return (
    <div
      className="my-6 flex justify-center [&_svg]:max-w-full [&_svg]:h-auto"
      dangerouslySetInnerHTML={{ __html: rendered.svg }}
    />
  );
}
