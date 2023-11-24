import DocsSidebar from "@/components/DocsSidebar";
import Alert from "@/components/DocsAlert";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex">
      <DocsSidebar />
      <main className="max-w-screen-xl p-4 pt-20 -ml-64 md:ml-0 lg:mx-auto">
        <div className="px-4">
          <article className="max-w-none format format-sm sm:format-base lg:format-lg ">
            <Alert
              color="info"
              html={`
                <!-- TODO: Link to EOL blogpost -->
                You're viewing documentation for the legacy version of Firezone
                  which has reached EOL. <a href="/kb">View the latest docs here</a>.
              `}
            />
            {children}
          </article>
        </div>
      </main>
    </div>
  );
}
