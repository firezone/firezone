"use client";

import { DocSearch } from "@docsearch/react";
import "@docsearch/css";
import Link from "next/link";

export default function SupportOptions() {
  return (
    <>
      <hr />
      <div className="mb-8">
        <h2 id="need-additional-help">Need additional help?</h2>
        <p>Try asking on one of our community-powered support channels:</p>
        <ul>
          <li>
            <Link href="https://discourse.firez.one/?utm_source=docs.firezone.dev">
              Discussion forums
            </Link>
            : Ask questions, report bugs, and suggest features.
          </li>
          <li>
            <Link href="https://discord.gg/DY8gxpSgep">Discord server</Link>:
            Join discussions, meet other users, and chat with the Firezone team
          </li>
          <li>
            <Link href="mailto:support@firezone.dev">Email us</Link>: We read
            every message.
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
