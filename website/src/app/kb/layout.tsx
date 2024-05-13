import KbSidebar from "@/components/KbSidebar";
import Alert from "@/components/DocsAlert";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex">
      <KbSidebar />
      <main className="p-4 pt-20 -ml-64 md:mx-auto max-w-full">
        <div className="px-4">
          <article className="max-w-full md:max-w-md lg:max-w-3xl xl:max-w-4xl tracking-[-0.01em] format format-sm md:format-md lg:format-lg format-firezone">
            {children}
          </article>
        </div>
      </main>
    </div>
  );
}
