// Adds GitHub-flavored markdown support to MDX
import nextMDX from "@next/mdx";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import rehypeStringify from "rehype-stringify";
import rehypeHighlight from "rehype-highlight";

// Add IDs to headings
import rehypeSlug from "rehype-slug";

// Add anchor links to headings with IDs
import rehypeAutolinkHeadings from "rehype-autolink-headings";
import { s } from "hastscript";

// Highlight.js languages
import langElixir from "highlight.js/lib/languages/elixir";
import langYaml from "highlight.js/lib/languages/yaml";
import langJson from "highlight.js/lib/languages/json";
import langBash from "highlight.js/lib/languages/bash";
import langRust from "highlight.js/lib/languages/rust";
import langRuby from "highlight.js/lib/languages/ruby";

const highlightLanguages = {
  elixir: langElixir,
  yaml: langYaml,
  json: langJson,
  bash: langBash,
  rust: langRust,
  ruby: langRuby,
};

/** @type {import('next').NextConfig} */
const nextConfig = {
  experimental: {
    typedRoutes: true,
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
      {
        hostname: "img.shields.io",
      },
      {
        hostname: "github.com",
      },
      {
        hostname: "avatars.githubusercontent.com",
      },
      {
        hostname: "www.gravatar.com",
      },
    ],
  },
};

const withMDX = nextMDX({
  extension: /\.mdx?$/,
  options: {
    remarkPlugins: [remarkGfm, remarkParse],
    rehypePlugins: [
      rehypeSlug,
      [
        rehypeAutolinkHeadings,
        {
          behavior: "append",
          // We want to render a link icon from HeroIcons
          content(node) {
            return [
              s(
                "svg",
                {
                  xmlns: "http://www.w3.org/2000/svg",
                  viewBox: "0 0 24 24",
                  width: 10,
                  height: 10,
                  color: "black",
                },
                s("path", {
                  fill: "currentColor",
                  fillRule: "evenodd",
                  d: "M19.902 4.098a3.75 3.75 0 00-5.304 0l-4.5 4.5a3.75 3.75 0 001.035 6.037.75.75 0 01-.646 1.353 5.25 5.25 0 01-1.449-8.45l4.5-4.5a5.25 5.25 0 117.424 7.424l-1.757 1.757a.75.75 0 11-1.06-1.06l1.757-1.757a3.75 3.75 0 000-5.304zm-7.389 4.267a.75.75 0 011-.353 5.25 5.25 0 011.449 8.45l-4.5 4.5a5.25 5.25 0 11-7.424-7.424l1.757-1.757a.75.75 0 111.06 1.06l-1.757 1.757a3.75 3.75 0 105.304 5.304l4.5-4.5a3.75 3.75 0 00-1.035-6.037.75.75 0 01-.354-1z",
                  clipRule: "evenodd",
                })
              ),
            ];
          },
        },
      ],
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
