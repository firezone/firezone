import DocsSidebar from "@/components/DocsSidebar";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <DocsSidebar />
      <main className="p-4 md:ml-64 h-auto pt-20">{children}</main>
    </div>
  );
}
