"use client";

import { DocSearch } from "@docsearch/react";
import "@docsearch/css";

export default function SupportOptions() {
  return (
    <>
      <hr />
      <div className="mb-8">
        <h2 id="need-additional-help">Need additional help?</h2>
        <p>Try asking on one of our community-powered support channels:</p>
        <ul>
          <li>
            <a href="https://discourse.firez.one/?utm_source=docs.firezone.dev">
              Discussion forums
            </a>
            : Ask questions, report bugs, and suggest features.
          </li>
          <li>
            <a href="https://join.slack.com/t/firezone-users/shared_invite/zt-111043zus-j1lP_jP5ohv52FhAayzT6w">
              Public Slack group
            </a>
            : join discussions, meet other users, and meet the contributors
          </li>
        </ul>
        <div className="flex">
          <span className="self-center">Or try searching the docs:</span>
          <span className="ml-2">
            <DocSearch
              insights
              appId="XXPZ9QVGFB"
              apiKey="66664e8765e1645ea0b500acebb0b0c2"
              indexName="firezone"
            />
          </span>
        </div>
      </div>
    </>
  );
}
