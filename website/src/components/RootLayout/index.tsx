import { Metadata } from "next";
import "@/app/globals.css";
import "highlight.js/styles/default.css";
import RootNavbar from "@/components/RootNavbar";
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
      <body className={source_sans_pro.className}>
        <div className="antialiased mx-auto max-w-8xl min-h-screen">
          <RootNavbar />
          {children}
        </div>
      </body>
    </html>
  );
}
