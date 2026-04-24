import { NextResponse, NextRequest } from "next/server";
import { proxy, config as proxyConfig } from "@/proxy";

// Paths that support markdown content negotiation (Accept: text/markdown)
const MARKDOWN_PATHS = new Set(["/", "/pricing", "/product", "/about", "/kb"]);

function wantsMarkdown(request: NextRequest): boolean {
  const accept = request.headers.get("accept") ?? "";
  return accept.includes("text/markdown");
}

export function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // Handle /dl/ redirect proxying (from proxy.ts)
  // proxy() returns NextResponse.redirect() when a match is found, else NextResponse.next()
  const proxyResult = proxy(request);
  if (proxyResult.headers.has("location")) {
    return proxyResult;
  }

  // Markdown content negotiation — RFC 8288 / Cloudflare Markdown for Agents
  if (wantsMarkdown(request) && MARKDOWN_PATHS.has(pathname)) {
    const slug = pathname === "/" ? "home" : pathname.replace(/^\//, "");
    const mdUrl = request.nextUrl.clone();
    mdUrl.pathname = `/api/md/${slug}`;
    return NextResponse.rewrite(mdUrl);
  }

  return NextResponse.next();
}

export const config = {
  matcher: [
    ...proxyConfig.matcher,
    // Match all pages that support markdown negotiation
    "/",
    "/pricing",
    "/product",
    "/about",
    "/kb",
  ],
};
