import RootLayout from "@/components/RootLayout";
import Providers from "@/components/Providers";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <Providers>
      <RootLayout>{children}</RootLayout>
    </Providers>
  );
}
