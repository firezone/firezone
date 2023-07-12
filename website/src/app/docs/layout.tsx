import DocsSidebar from "@/components/DocsSidebar";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex">
      <DocsSidebar />
      <main className="max-w-screen-xl p-4 pt-20 -ml-64 md:ml-0 lg:mx-auto">
        <div className="px-4">
          <article className="max-w-none format format-sm sm:format-base lg:format-lg dark:format-invert">
            {children}
          </article>
        </div>
      </main>
    </div>
  );
}
