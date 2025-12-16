// Adds GitHub-flavored markdown support to MDX
import nextMDX from "@next/mdx";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import rehypeStringify from "rehype-stringify";
import rehypeHighlight from "rehype-highlight";
import redirects from "./redirects.js";

// Add IDs to headings
import rehypeSlug from "rehype-slug";

// Add anchor links to headings with IDs
import rehypeAutolinkHeadings from "rehype-autolink-headings";

// Highlight.js languages
import langElixir from "highlight.js/lib/languages/elixir";
import langYaml from "highlight.js/lib/languages/yaml";
import langJson from "highlight.js/lib/languages/json";
import langBash from "highlight.js/lib/languages/bash";
import langRust from "highlight.js/lib/languages/rust";
import langRuby from "highlight.js/lib/languages/ruby";
import langPowerShell from "highlight.js/lib/languages/powershell";

const highlightLanguages = {
  elixir: langElixir,
  yaml: langYaml,
  json: langJson,
  bash: langBash,
  rust: langRust,
  ruby: langRuby,
  powershell: langPowerShell,
};

/** @type {import('next').NextConfig} */
const nextConfig = {
  typedRoutes: true,
  async headers() {
    return [
      {
        source: "/(.*)",
        headers: [
          {
            key: "Permissions-Policy",
            value: "browsing-topics=()",
          },
        ],
      },
    ];
  },
  async redirects() {
    return redirects;
  },
  // Proxy GitHub requests to avoid CORS issues
  async rewrites() {
    return [
      {
        source: "/api/github/:path*",
        destination: "https://github.com/:path*",
      },
    ];
  },
  pageExtensions: ["js", "jsx", "md", "mdx", "ts", "tsx"],
  images: {
    dangerouslyAllowSVG: true,
    remotePatterns: [
      { hostname: "runacap.com" },
      { hostname: "api.star-history.com" },
      { hostname: "github.com" },
      { hostname: "avatars.githubusercontent.com" },
      { hostname: "www.gravatar.com" },
    ],
  },
};

const withMDX = nextMDX({
  extension: /\.mdx?$/,
  options: {
    remarkPlugins: [remarkGfm, remarkParse],
    rehypePlugins: [
      rehypeSlug,
      [rehypeAutolinkHeadings, { behavior: "wrap" }],
      rehypeStringify,
      [
        rehypeHighlight,
        {
          ignoreMissing: true,
          languages: highlightLanguages,
        },
      ],
    ],
  },
});

export default withMDX(nextConfig);
