import KbSidebar from "@/components/KbSidebar";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex">
      <KbSidebar />
      <main className="max-w-screen-xl p-4 pt-20 -ml-64 md:ml-0 lg:mx-auto">
        <div className="px-4">
          <article className="max-w-none format format-sm sm:format-base lg:format-lg ">
            {children}
          </article>
        </div>
      </main>
    </div>
  );
}
