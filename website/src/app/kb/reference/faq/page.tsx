import { join } from "node:path";
import Content, { frontmatter } from "./readme.mdx";
import { Metadata } from "next";
import { metadataFromFrontmatter } from "@/lib/metadata-from-frontmatter";
import { parseFaqEntries } from "@/lib/parse-faq-mdx";
import JsonLd from "@/components/JsonLd";
import { faqPageSchema } from "@/components/JsonLd/schemas";

export const metadata: Metadata = metadataFromFrontmatter(frontmatter);

export default async function Page() {
  // Parse Q&A out of the same MDX the page renders so the FAQPage JSON-LD
  // can never drift from the visible content.
  const faqEntries = await parseFaqEntries(
    join(process.cwd(), "src/app/kb/reference/faq/readme.mdx")
  );
  return (
    <>
      <JsonLd data={faqPageSchema(faqEntries)} />
      <Content />
    </>
  );
}
