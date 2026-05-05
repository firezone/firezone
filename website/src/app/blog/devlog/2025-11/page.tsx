import _Page from "./_page";
import ArticleJsonLd from "@/components/Blog/ArticleJsonLd";
import { frontmatter } from "./readme.mdx";
import { asBlogFrontmatter } from "@/types/frontmatter";
import { Metadata } from "next";
import { metadataFromFrontmatter } from "@/lib/metadata-from-frontmatter";

export const metadata: Metadata = metadataFromFrontmatter(frontmatter);

export default function Page() {
  const fm = asBlogFrontmatter(frontmatter);
  return (
    <>
      <ArticleJsonLd
        title={fm.postTitle ?? fm.title}
        description={fm.description}
        authorName={fm.authorName}
        date={fm.date}
        path="/blog/devlog/2025-11"
      />
      <_Page />
    </>
  );
}
