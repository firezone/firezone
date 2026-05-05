import fs from "node:fs";
import path from "node:path";

// Embeds an SVG/PNG from /public/images as a base64 data URL so it can be
// referenced from `next/og`'s ImageResponse, which doesn't fetch external
// URLs at render time. We read the file once at module load and let the
// Node runtime cache the resulting string.
function dataUrl(filename: string, mime: string): string {
  const buf = fs.readFileSync(
    path.join(process.cwd(), "public/images", filename)
  );
  return `data:${mime};base64,${buf.toString("base64")}`;
}

// logo-text-dark.svg = flame + "Firezone" wordmark filled white, designed
// for dark backgrounds — matches every OG gradient we render.
export const FIREZONE_LOGO_DATA_URL = dataUrl(
  "logo-text-dark.svg",
  "image/svg+xml"
);
