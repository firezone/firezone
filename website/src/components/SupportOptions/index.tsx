"use client";

import Link from "next/link";
import KbSearch from "@/components/KbSearch";

export default function SupportOptions() {
  return (
    <>
      <hr />
      <div className="mb-8">
        <h2 id="need-additional-help">Need additional help?</h2>
        <p>
          See{" "}
          <Link href="/support" className="text-accent-500 hover:underline">
            all support options
          </Link>{" "}
          or try asking on one of our community-powered support channels:
        </p>
        <ul>
          <li>
            <Link href="https://www.github.com/firezone/firezone/discussions">
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
          <span className="ml-6 w-64">
            <KbSearch />
          </span>
        </div>
      </div>
    </>
  );
}
