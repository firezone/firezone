import { NextResponse, NextRequest } from "next/server";
import { proxy, config as proxyConfig } from "@/proxy";

// Top-level marketing pages that support markdown content negotiation
const STATIC_MARKDOWN_PATHS = new Set(["/", "/pricing", "/product", "/about"]);

function wantsMarkdown(request: NextRequest): boolean {
  const accept = request.headers.get("accept") ?? "";
  return accept.includes("text/markdown");
}

export function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // Handle /dl/ redirect proxying (from proxy.ts)
  // proxy() returns NextResponse.redirect() (3xx) when a match is found, else NextResponse.next()
  const proxyResult = proxy(request);
  if (proxyResult.status >= 300 && proxyResult.status < 400) {
    return proxyResult;
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

export const config = {
  matcher: [
    ...proxyConfig.matcher,
    // Match top-level pages and all /kb/** documentation pages
    "/",
    "/pricing",
    "/product",
    "/about",
    "/kb",
    "/kb/:path*",
  ],
};
