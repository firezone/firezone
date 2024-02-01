import { DocSearch } from "@docsearch/react";
import "@docsearch/css";

export default function SearchForm() {
  return (
    <div className="pb-3 -ml-1 flex justify-start border-b border-neutral-200 ">
      <DocSearch
        insights
        appId="XXPZ9QVGFB"
        apiKey="66664e8765e1645ea0b500acebb0b0c2"
        indexName="firezone"
      />
    </div>
  );
}
