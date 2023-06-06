import DocsSidebar from "@/components/DocsSidebar";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="antialiased">
      <DocsSidebar />
      <main className="max-w-none format lg:format-lg p-4 md:ml-64 h-full fixed overflow-y-auto pt-20 pb-6">
        {children}
      </main>
    </div>
  );
}
