import { NextResponse, NextRequest } from "next/server";

// Top-level marketing pages that support markdown content negotiation
const STATIC_MARKDOWN_PATHS = new Set(["/", "/pricing", "/product", "/about"]);

function wantsMarkdown(request: NextRequest): boolean {
  const accept = request.headers.get("accept") ?? "";
  return accept.includes("text/markdown");
}

// This proxy is needed because NextJS doesn't populate params in the destination
// more than once. See https://github.com/vercel/next.js/issues/66891
const versionedRedirects = [
  {
    source: /^\/dl\/firezone-client-macos\/(\d+\.\d+\.\d+)$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/macos-client-:version/firezone-macos-client-:version.dmg",
  },
  {
    source: /^\/dl\/firezone-client-macos\/pkg\/(\d+\.\d+\.\d+)$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/macos-client-:version/firezone-macos-client-:version.pkg",
  },
  {
    source: /^\/dl\/firezone-client-android\/(\d+\.\d+\.\d+)$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/android-client-:version/firezone-android-client-:version.apk",
  },
  {
    source: /^\/dl\/firezone-client-gui-windows\/(\d+\.\d+\.\d+)\/x86_64$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/gui-client-:version/firezone-client-gui-windows_:version_x86_64.msi",
  },
  {
    source: /^\/dl\/firezone-client-headless-windows\/(\d+\.\d+\.\d+)\/x86_64$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/headless-client-:version/firezone-client-headless-windows_:version_x86_64.exe",
  },
  {
    source: /^\/dl\/firezone-client-gui-linux\/(\d+\.\d+\.\d+)\/x86_64$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/gui-client-:version/firezone-client-gui-linux_:version_x86_64.deb",
  },
  {
    source: /^\/dl\/firezone-client-gui-linux\/(\d+\.\d+\.\d+)\/aarch64$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/gui-client-:version/firezone-client-gui-linux_:version_aarch64.deb",
  },
  {
    source: /^\/dl\/firezone-client-headless-linux\/(\d+\.\d+\.\d+)\/x86_64$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/headless-client-:version/firezone-client-headless-linux_:version_x86_64",
  },
  {
    source: /^\/dl\/firezone-client-headless-linux\/(\d+\.\d+\.\d+)\/aarch64$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/headless-client-:version/firezone-client-headless-linux_:version_aarch64",
  },
  {
    source: /^\/dl\/firezone-client-headless-linux\/(\d+\.\d+\.\d+)\/armv7$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/headless-client-:version/firezone-client-headless-linux_:version_armv7",
  },
  {
    source: /^\/dl\/firezone-gateway\/(\d+\.\d+\.\d+)\/x86_64$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/gateway-:version/firezone-gateway_:version_x86_64",
  },
  {
    source: /^\/dl\/firezone-gateway\/(\d+\.\d+\.\d+)\/aarch64$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/gateway-:version/firezone-gateway_:version_aarch64",
  },
  {
    source: /^\/dl\/firezone-gateway\/(\d+\.\d+\.\d+)\/armv7$/,
    destination:
      "https://www.github.com/firezone/firezone/releases/download/gateway-:version/firezone-gateway_:version_armv7",
  },
];

export const config = {
  matcher: [
    "/dl/firezone-client-macos/(\\d+).(\\d+).(\\d+)",
    "/dl/firezone-client-macos/pkg/(\\d+).(\\d+).(\\d+)",
    "/dl/firezone-client-android/(\\d+).(\\d+).(\\d+)",
    "/dl/firezone-client-gui-windows/(\\d+).(\\d+).(\\d+)/x86_64",
    "/dl/firezone-client-headless-windows/(\\d+).(\\d+).(\\d+)/x86_64",
    "/dl/firezone-client-gui-linux/(\\d+).(\\d+).(\\d+)/x86_64",
    "/dl/firezone-client-gui-linux/(\\d+).(\\d+).(\\d+)/aarch64",
    "/dl/firezone-client-headless-linux/(\\d+).(\\d+).(\\d+)/x86_64",
    "/dl/firezone-client-headless-linux/(\\d+).(\\d+).(\\d+)/aarch64",
    "/dl/firezone-client-headless-linux/(\\d+).(\\d+).(\\d+)/armv7",
    "/dl/firezone-gateway/(\\d+).(\\d+).(\\d+)/x86_64",
    "/dl/firezone-gateway/(\\d+).(\\d+).(\\d+)/aarch64",
    "/dl/firezone-gateway/(\\d+).(\\d+).(\\d+)/armv7",
    // Markdown content negotiation
    "/",
    "/pricing",
    "/product",
    "/about",
    "/kb",
    "/kb/:path*",
  ],
};

// Next.js 16 calls the `proxy` export from proxy.ts (not `middleware`).
// See: next/dist/build/templates/middleware.js line:
//   const handlerUserland = (isProxy ? mod.proxy : mod.middleware) || mod.default;
export function proxy(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // Handle /dl/ download redirects
  for (const redirect of versionedRedirects) {
    const match = pathname.match(redirect.source);

    if (match) {
      const version = match[1];
      const destination = redirect.destination.replace(/:version/g, version);
      return NextResponse.redirect(destination);
    }
  }

  // Markdown content negotiation — RFC 8288 / Cloudflare Markdown for Agents
  // Match top-level marketing pages and all /kb/** documentation pages
  const isMarkdownPath =
    STATIC_MARKDOWN_PATHS.has(pathname) ||
    pathname === "/kb" ||
    pathname.startsWith("/kb/");

  if (wantsMarkdown(request) && isMarkdownPath) {
    const slug = pathname === "/" ? "home" : pathname.replace(/^\//, "");
    const mdUrl = request.nextUrl.clone();
    mdUrl.pathname = `/api/md/${slug}`;
    return NextResponse.rewrite(mdUrl);
  }

  return NextResponse.next();
}
