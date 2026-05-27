import Content, { frontmatter } from "./readme.mdx";
import { Metadata } from "next";
import { metadataFromFrontmatter } from "@/lib/metadata-from-frontmatter";

export const metadata: Metadata = metadataFromFrontmatter(frontmatter);

export default function Page() {
  return <Content />;
}
