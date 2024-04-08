import Link from "next/link";
import DocsSidebar from "@/components/DocsSidebar";
import Banner from "./banner.mdx";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex">
      <DocsSidebar />
      <main className="p-4 pt-20 -ml-64 md:ml-0 lg:mx-auto">
        <div className="px-4">
          <article className="max-w-screen-md format format-sm">
            {children}
          </article>
        </div>
      </main>
    </div>
  );
}
