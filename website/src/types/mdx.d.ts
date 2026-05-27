declare module "*.mdx" {
  import type { MDXProps } from "mdx/types";
  import type { MdxFrontmatter } from "@/types/frontmatter";

  export default function MDXContent(props: MDXProps): JSX.Element;

  // Exported by remark-mdx-frontmatter — the parsed YAML block at the top
  // of the MDX file. Typed strictly so typos in YAML keys fail the build.
  export const frontmatter: MdxFrontmatter;
}
