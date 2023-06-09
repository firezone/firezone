import Footer from "@/components/Footer";

export default function Layout({ children }: { children: React.ReactNode }) {
  return <div className="flex flex-col">{children}</div>;
}
