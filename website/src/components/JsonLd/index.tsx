// Anything `JSON.stringify`-able. We intentionally use `unknown` rather than a
// recursive `JsonLdValue` union because TypeScript can't narrow the
// `Record<string, unknown>` that our schema builders return back into a
// recursive union without per-call casts.
export type JsonLdData = Record<string, unknown>;

export default function JsonLd({ data }: { data: JsonLdData }) {
  return (
    <script
      // React 19 refuses to render sync <script> elements outside the
      // main <head> without async. JSON-LD is inert data so async has no
      // runtime effect, but it satisfies React's ordering requirement so
      // the tag can sit in <body> as Google recommends.
      async
      type="application/ld+json"
      dangerouslySetInnerHTML={{
        __html: JSON.stringify(data).replace(/</g, "\\u003c"),
      }}
    />
  );
}
