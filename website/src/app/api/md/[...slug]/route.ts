import { NextResponse } from "next/server";
import { readFileSync } from "fs";
import { join } from "path";

// Static markdown content for top-level marketing pages
// Served when clients send Accept: text/markdown (Markdown for Agents)
const PAGE_MARKDOWN: Record<string, string> = {
  home: `# Firezone: Zero Trust Access That Scales

Firezone is a fast, flexible VPN replacement built on WireGuard® that eliminates
tedious configuration and integrates with your identity provider.

## What is Firezone?

Firezone provides zero-trust network access (ZTNA) for teams of any size.
It replaces legacy VPNs with a modern, identity-aware solution that enforces
least-privilege access to your private resources.

## Key Features

- **WireGuard-based**: Fast, modern tunneling protocol for all devices
- **Identity provider integration**: Works with Okta, Google, Entra, and any OIDC provider
- **Zero-trust policies**: Enforce per-user, per-group access policies
- **Multi-platform clients**: macOS, Windows, Linux, iOS, Android, Chrome
- **REST API**: Full programmatic control via [REST API](https://api.firezone.dev/swaggerui)
- **Self-hosted or cloud**: Deploy on your infrastructure or use our managed cloud

## Getting Started

- Sign up at <https://app.firezone.dev>
- Read the docs at <https://www.firezone.dev/kb>
- REST API docs at <https://api.firezone.dev/swaggerui>
- OpenAPI spec at <https://api.firezone.dev/openapi>

## Links

- Homepage: <https://www.firezone.dev>
- Product: <https://app.firezone.dev>
- API: <https://api.firezone.dev>
- Documentation: <https://www.firezone.dev/kb>
- Pricing: <https://www.firezone.dev/pricing>
- GitHub: <https://github.com/firezone/firezone>
`,
  pricing: `# Firezone Pricing

Firezone offers flexible pricing for teams of all sizes.

Visit <https://www.firezone.dev/pricing> for current pricing details.

## Plans

- **Starter**: Free tier for small teams
- **Team**: For growing organizations
- **Enterprise**: Custom pricing for large deployments

## Get Started

Sign up at <https://app.firezone.dev> or [contact us](https://www.firezone.dev/contact) for enterprise pricing.
`,
  product: `# Firezone Product Overview

Firezone is a zero-trust network access (ZTNA) platform built on WireGuard®.

## How It Works

1. Deploy Firezone Gateways on your network
2. Install Firezone clients on user devices
3. Define policies to control who can access what
4. Users authenticate via your identity provider

## Architecture

- **Portal** (<https://app.firezone.dev>): Web UI and API for managing your deployment
- **Gateways**: Lightweight servers that proxy traffic to your private resources
- **Clients**: Native apps for macOS, Windows, Linux, iOS, Android, and Chrome

## Resources

- [Documentation](https://www.firezone.dev/kb)
- [REST API](https://api.firezone.dev/swaggerui)
- [GitHub](https://github.com/firezone/firezone)
`,
  about: `# About Firezone

Firezone is building the future of network security.

We provide zero-trust network access (ZTNA) that replaces legacy VPNs
with a modern, scalable, and easy-to-manage solution.

## Company

Firezone is an open-source company committed to transparency, security, and
developer-friendly tooling.

- GitHub: <https://github.com/firezone/firezone>
- Contact: <https://www.firezone.dev/contact>
`,
};

// Allowed path segment characters (prevent directory traversal)
const SAFE_SEGMENT_RE = /^[a-zA-Z0-9_-]+$/;

/**
 * Read and clean a KB MDX file for markdown delivery.
 * Strips MDX import lines and JSX-style comments; the remaining content is
 * standard CommonMark that agents can consume directly.
 */
function readKbMdx(segments: string[]): string | null {
  // Validate every segment before building the path
  if (!segments.every((s) => SAFE_SEGMENT_RE.test(s))) {
    return null;
  }

  const filePath = join(
    process.cwd(),
    "src",
    "app",
    "kb",
    ...segments,
    "readme.mdx"
  );

  try {
    const raw = readFileSync(filePath, "utf-8");
    return raw
      .replace(/^import .+$/gm, "")   // strip import lines
      .replace(/\{\/\*[\s\S]*?\*\/\}/g, "") // strip JSX comments
      .trim();
  } catch {
    return null;
  }
}

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ slug: string[] }> }
) {
  const { slug } = await params;

  let markdown: string | null = null;

  if (slug[0] === "kb") {
    // /kb and /kb/** — serve the real MDX source as markdown
    const kbSegments = slug.slice(1); // strip the "kb" prefix
    markdown = readKbMdx(kbSegments);
  } else {
    // Top-level marketing pages — use hardcoded summaries
    markdown = PAGE_MARKDOWN[slug[0]] ?? null;
  }

  if (!markdown) {
    return new NextResponse("Not Found", { status: 404 });
  }

  return new NextResponse(markdown, {
    status: 200,
    headers: {
      "Content-Type": "text/markdown; charset=utf-8",
      "Cache-Control": "max-age=3600",
    },
  });
}

