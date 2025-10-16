"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export default function DocsFeedback() {
  const pathname = usePathname();
  const issueUrl = new URL(
    `https://www.github.com/firezone/firezone/issues/new?title=docs: Feedback for page ${pathname}`
  );

  return (
    <div>
      Found a problem with this page?{" "}
      <Link
        href={issueUrl}
        className="text-accent-500 underline hover:no-underline"
      >
        Open an issue
      </Link>
    </div>
  );
}
