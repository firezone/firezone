import React from "react";

interface TimelineEntry {
  time: string;
  event: string;
}

interface TimelineTableProps {
  entries: TimelineEntry[];
}

export default function TimelineTable({ entries }: TimelineTableProps) {
  return (
    <table className="mt-4 mb-8 border-separate border-spacing-0">
      <tbody>
        {entries.map((entry, index) => (
          <tr key={index}>
            <td
              className={`align-top pr-4 w-[200px] border-none font-bold ${
                index === entries.length - 1 ? "pb-0" : "pb-4"
              }`}
            >
              {entry.time}
            </td>
            <td
              className={`border-none ${
                index === entries.length - 1 ? "pb-0" : "pb-4"
              }`}
            >
              {entry.event}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
