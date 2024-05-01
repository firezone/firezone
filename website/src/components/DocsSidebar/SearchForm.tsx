import { DocSearch } from "@docsearch/react";
import "@docsearch/css";

export default function SearchForm() {
  // Keep /docs search in /docs (pre-1.0), and exclude /kb (>= 1.0)
  const excludePathRegex = new RegExp(/^\/kb/);

  return (
    <div className="pb-3 -ml-1 flex justify-start border-b border-neutral-200 ">
      <DocSearch
        insights
        appId="XXPZ9QVGFB"
        apiKey="66664e8765e1645ea0b500acebb0b0c2"
        indexName="firezone"
        transformItems={(items) => {
          return items.filter((item) => {
            if (item.url) {
              const pathname = new URL(item.url).pathname;
              if (pathname.match(excludePathRegex)) return false;
            }
            return true;
          });
        }}
      />
    </div>
  );
}
