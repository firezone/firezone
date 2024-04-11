import fs from "fs";
import path from "path";

export default function LastUpdated({ dirname }: { dirname: string }) {
  // timestamps.json was generated during build
  const timestampsFile = path.resolve("timestamps.json");
  const timestampsData = fs.readFileSync(timestampsFile, "utf-8");
  const timestamps = JSON.parse(timestampsData);

  // Hack to get the path to the readme file
  const filePath = path.join(
    "src",
    dirname.split(".next/server")[1],
    "readme.mdx"
  );

  const timestamp = timestamps[filePath];

  if (timestamp) {
    return (
      <div className="flex justify-end text-sm text-gray-500">
        Last updated: {timestamp}
      </div>
    );
  } else {
    return null;
  }
}
