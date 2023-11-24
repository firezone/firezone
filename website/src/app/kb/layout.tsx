import KbSidebar from "@/components/KbSidebar";
import Alert from "@/components/DocsAlert";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex">
      <KbSidebar />
      <main className="max-w-screen-xl p-4 pt-20 -ml-64 md:ml-0 lg:mx-auto">
        <div className="px-4">
          <article className="max-w-none format format-sm sm:format-base lg:format-lg ">
            <Alert
              color="info"
              html={`
                You're viewing documentation for the upcoming 1.x version of Firezone, currently in beta.
                  <a href="/docs">View the legacy docs here</a>.
              `}
            />
            {children}
          </article>
        </div>
      </main>
    </div>
  );
}
