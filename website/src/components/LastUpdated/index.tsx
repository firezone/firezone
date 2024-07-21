"use client";

import { usePathname } from "next/navigation";

type Timestamps = { [key: string]: string };

export default function LastUpdated({
  timestamps,
}: {
  timestamps: Timestamps;
}) {
  const pathname = usePathname();
  const timestamp = timestamps[pathname];

  if (timestamp) {
    return <div>Last updated: {timestamp}</div>;
  } else {
    return null;
  }
}
