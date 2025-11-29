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
    <table
      style={{
        borderCollapse: "separate",
        borderSpacing: "0",
        marginTop: "1rem",
        marginBottom: "2rem",
      }}
    >
      <tbody>
        {entries.map((entry, index) => (
          <tr key={index}>
            <td
              style={{
                verticalAlign: "top",
                paddingRight: "1rem",
                paddingBottom: index === entries.length - 1 ? "0" : "1rem",
                width: "200px",
                border: "none",
              }}
            >
              <strong>{entry.time}</strong>
            </td>
            <td
              style={{
                paddingBottom: index === entries.length - 1 ? "0" : "1rem",
                border: "none",
              }}
            >
              {entry.event}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

