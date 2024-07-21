import fs from "fs";
import path from "path";

import LastUpdated from "@/components/LastUpdated";
import DocsFeedback from "@/components/DocsFeedback";
import KbSidebar from "@/components/KbSidebar";

export default function Layout({ children }: { children: React.ReactNode }) {
  // timestamps.json was generated during build
  const timestampsFile = path.resolve("timestamps.json");
  const timestampsData = fs.readFileSync(timestampsFile, "utf-8");
  const timestamps = JSON.parse(timestampsData);

  return (
    <div className="flex">
      <KbSidebar />
      <main className="p-4 pt-32 -ml-64 md:mx-auto max-w-full">
        <div className="px-4">
          <article className="max-w-full md:max-w-md lg:max-w-3xl xl:max-w-4xl tracking-[-0.01em] format format-sm md:format-md lg:format-lg format-firezone">
            {children}
          </article>
          <div className="mt-8 flex justify-between flex-wrap text-sm text-neutral-600">
            <DocsFeedback />
            <LastUpdated timestamps={timestamps} />
          </div>
        </div>
      </main>
    </div>
  );
}
