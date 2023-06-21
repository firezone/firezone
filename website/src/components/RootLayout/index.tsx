import { Metadata } from "next";
import "@/app/globals.css";
import "highlight.js/styles/a11y-dark.css";
import RootNavbar from "@/components/RootNavbar";
import Providers from "@/components/Providers";
import Footer from "@/components/Footer";
import { Source_Sans_Pro } from "next/font/google";
const source_sans_pro = Source_Sans_Pro({
  subsets: ["latin"],
  weight: ["200", "300", "400", "600", "700", "900"],
});

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <Providers>
        <body className={source_sans_pro.className}>
          <div className="h-auto antialiased">
            <RootNavbar />
            {children}
            <Footer />
          </div>
        </body>
      </Providers>
    </html>
  );
}
