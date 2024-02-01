import DocsSidebar from "@/components/DocsSidebar";
import Alert from "@/components/DocsAlert";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex">
      <DocsSidebar />
      <main className="p-4 pt-20 -ml-64 md:ml-0 lg:mx-auto">
        <div className="px-4">
          <article className="max-w-screen-md format format-sm">
            <Alert
              color="info"
              html={`
                You're viewing documentation for the legacy version of Firezone.
                <a href="/kb">View the latest docs here</a>.
              `}
            />
            {children}
          </article>
        </div>
      </main>
    </div>
  );
}
