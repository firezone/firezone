import type { Route } from "next";

// Validates a URL string at module-load time and returns it as a plain
// string. Plain strings are safe to pass across the server -> client
// component boundary; raw `URL` instances are not (Next.js / React 19 throws
// "URL objects are not supported" in production server-component renders).
//
// Use this anywhere we previously wrote `new URL("https://...")` only to
// hand the result to a Client Component prop (Link href, Icon url, etc.).
// Throws synchronously if the input is not a parseable absolute URL, so an
// invalid literal will fail the build / module load just like `new URL`
// would have.
//
// The return type is cast to `Route` so the result satisfies typedRoutes'
// `Link href` prop without a per-call cast. Typed routes are for internal
// app paths; this is the documented escape hatch for external URLs.
export function validUrl(spec: string): Route {
  return new URL(spec).toString() as Route;
}
