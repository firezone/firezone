import fs from "fs";
import path from "path";

import LastUpdated from "@/components/LastUpdated";
import DocsSidebar from "@/components/DocsSidebar";
import Banner from "./banner.mdx";

export default function Layout({ children }: { children: React.ReactNode }) {
  // timestamps.json was generated during build
  const timestampsFile = path.resolve("timestamps.json");
  const timestampsData = fs.readFileSync(timestampsFile, "utf-8");
  const timestamps = JSON.parse(timestampsData);

  return (
    <div className="flex">
      <DocsSidebar />
      <main className="p-4 pt-32 -ml-64 md:ml-0 lg:mx-auto">
        <div className="px-4">
          <article className="max-w-screen-md tracking-[-0.01em] format format-sm md:format-md lg:format-lg format-firezone">
            <Banner />
            {children}
          </article>
          <div className="mt-8 flex justify-end text-sm text-neutral-600">
            <LastUpdated timestamps={timestamps} />
          </div>
        </div>
      </main>
    </div>
  );
}
