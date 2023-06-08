import DocsSidebar from "@/components/DocsSidebar";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex">
      <DocsSidebar />
      <main className="format lg:format-lg p-4 pt-20 mr-auto max-w-8xl">
        <div className="justify-between px-4 max-w-screen-xl">
          <article className="mx-auto w-full max-w-3xl format format-sm sm:format-base lg:format-lg format-blue dark:format-invert">
            {children}
          </article>
        </div>
      </main>
    </div>
  );
}
