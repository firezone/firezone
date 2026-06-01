import fs from "fs";
import path from "path";
import { Metadata } from "next";

import LastUpdated from "@/components/LastUpdated";
import DocsFeedback from "@/components/DocsFeedback";
import KbSidebar from "@/components/KbSidebar";

export const metadata: Metadata = {
  title: {
    default: "Zero Trust Access Documentation | Firezone Docs",
    template: "%s | Firezone Docs",
  },
  description:
    "Read Firezone's docs: deploy gateways, configure clients, integrate identity providers, and write zero trust policies. Step-by-step guides for every team.",
};

// NOTE: Breadcrumb JSON-LD used to be emitted from this layout via
// `headers()` to read the current path. Calling `headers()` opted the entire
// /kb subtree out of static prerendering, costing every doc page an SSR
// render on each request. The breadcrumb labels were also being computed by
// title-casing raw slugs, which produced inaccurate names ("Rest Api" for
// /kb/reference/rest-api). The cheap, slug-driven version is removed; a
// per-page emission backed by frontmatter titles is the right replacement
// when we add it back.

export default function Layout({ children }: { children: React.ReactNode }) {
  // timestamps.json was generated during build
  const timestampsFile = path.resolve("timestamps.json");
  const timestampsData = fs.readFileSync(timestampsFile, "utf-8");
  const timestamps = JSON.parse(timestampsData);

  return (
    <div className="flex bg-neutral-50">
      <KbSidebar />
      <main className="p-4 pt-32 pb-14 -ml-64 md:mx-auto max-w-full bg-neutral-50">
        <div className="px-4">
          <article className="kb-article max-w-full md:max-w-md lg:max-w-3xl xl:max-w-4xl format format-sm md:format-sm lg:format-base format-firezone">
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
