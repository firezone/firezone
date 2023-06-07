import DocsSidebar from "@/components/DocsSidebar";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <DocsSidebar />
      <main className="max-w-none format lg:format-lg p-4 md:ml-64 h-auto pt-20">
        <div className="flex justify-between px-4 mx-auto max-w-screen-xl">
          <article className="mx-auto w-full max-w-3xl format format-sm sm:format-base lg:format-lg format-blue dark:format-invert">
            {children}
          </article>
        </div>
      </main>
    </div>
  );
}
