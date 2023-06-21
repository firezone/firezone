import { DocSearch } from "@docsearch/react";
import "@docsearch/css";

export default function SearchForm() {
  return (
    <div className="pb-3 -ml-1 flex justify-start border-b border-gray-200 dark:border-gray-700">
      <DocSearch
        appId="XXPZ9QVGFB"
        apiKey="c0b0c0a0b0c0a0b0c0a0b0c0a0b0c0a0"
        indexName="firezone"
      />
    </div>
  );
}
