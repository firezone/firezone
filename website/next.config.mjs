// Adds GitHub-flavored markdown support to MDX
import nextMDX from "@next/mdx";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import rehypeStringify from "rehype-stringify";
import rehypeHighlight from "rehype-highlight";
import rehypeAutolinkHeadings from "rehype-autolink-headings";
import rehypeSlug from "rehype-slug";
import langElixir from "highlight.js/lib/languages/elixir";
import langYaml from "highlight.js/lib/languages/yaml";
import langJson from "highlight.js/lib/languages/json";
import langBash from "highlight.js/lib/languages/bash";
import langRust from "highlight.js/lib/languages/rust";

const highlightLanguages = {
  elixir: langElixir,
  yaml: langYaml,
  json: langJson,
  bash: langBash,
  rust: langRust,
};

/** @type {import('next').NextConfig} */
const nextConfig = {
  pageExtensions: ["js", "jsx", "ts", "tsx", "md", "mdx"],
  images: {
    remotePatterns: [
      {
        hostname: "user-images.githubusercontent.com",
      },
    ],
  },
};

const withMDX = nextMDX({
  extension: /\.mdx?$/,
  options: {
    remarkPlugins: [remarkGfm, remarkParse, remarkRehype],
    rehypePlugins: [
      rehypeAutolinkHeadings,
      rehypeSlug,
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
