"use client";
import "@/styles/docsearch.css";
import { useEffect, useRef } from "react";
import { DocSearch } from "@docsearch/react";
import "@docsearch/css";

export default function KbSearch({
  buttonText = "Search",
  excludePathRegex = new RegExp(/^\/docs/),
}: {
  buttonText?: string;
  excludePathRegex?: RegExp;
}) {
  const buttonRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!buttonRef.current) return;

    // Find button and update its text
    buttonRef.current.getElementsByClassName(
      "DocSearch-Button-Placeholder",
    )[0].textContent = buttonText;
  }, []);

  return (
    <div ref={buttonRef}>
      <DocSearch
        placeholder="Search the knowledge base"
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
