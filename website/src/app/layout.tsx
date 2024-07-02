import RootLayout from "@/components/RootLayout";
import Providers from "@/components/Providers";
import { DrawerProvider } from "@/components/Providers/DrawerProvider";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <Providers>
      <DrawerProvider>
        <RootLayout>{children}</RootLayout>
      </DrawerProvider>
    </Providers>
  );
}
