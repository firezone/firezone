import fs from "fs";
import path from "path";

export default function LastUpdated({ dirname }: { dirname: string }) {
  // Hack to get the path to the readme file
  const filePath = path.join(
    process.cwd(),
    "src",
    dirname.split(".next/server")[1],
    "readme.mdx"
  );

  if (fs.existsSync(filePath)) {
    const stats = fs.statSync(filePath);
    const lastUpdated = new Date(stats.mtime).toLocaleDateString("en-US", {
      year: "numeric",
      month: "long",
      day: "numeric",
    });

    return (
      <div className="flex justify-end text-sm text-gray-500">
        Last updated: {lastUpdated}
      </div>
    );
  } else {
    return null;
  }
}
