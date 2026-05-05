import JsonLd from "@/components/JsonLd";
import { articleSchema, SITE_URL } from "@/components/JsonLd/schemas";

// `path` is passed explicitly by each blog page so this component stays
// fully static. We previously read it via `headers()`, but that opts every
// blog post out of static prerendering — every page knows its own slug at
// build time, so threading the path through props keeps the cache.
export default function ArticleJsonLd({
  title,
  description,
  authorName,
  date,
  path,
}: {
  title: string;
  description?: string;
  authorName: string;
  date: string;
  path: string;
}) {
  const url = `${SITE_URL}${path}`;
  return (
    <JsonLd
      data={articleSchema({ title, description, authorName, date, url })}
    />
  );
}
