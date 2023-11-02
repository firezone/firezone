import { Metadata } from "next";
import Link from "next/link";

import "@/app/globals.css";
import "highlight.js/styles/a11y-dark.css";
import RootNavbar from "@/components/RootNavbar";
import Script from "next/script";
import Banner from "@/components/Banner";
import Providers from "@/components/Providers";
import Footer from "@/components/Footer";
import { Public_Sans } from "next/font/google";
const public_sans = Public_Sans({
  subsets: ["latin"],
  weight: ["100", "200", "300", "400", "500", "600", "700", "800", "900"],
});
import { HiArrowLongRight } from "react-icons/hi2";

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <Script
        src="https://app.termly.io/embed.min.js"
        data-auto-block="on"
        data-website-uuid="c4df1a31-22d9-4000-82e6-a86cbec0bba0"
      ></Script>
      <Providers>
        <body className={public_sans.className}>
          <div className="min-h-screen h-auto antialiased">
            <RootNavbar />
            {children}
            <Footer />
          </div>
          <Script
            id="hs-script-loader"
            async
            defer
            src="//js.hs-scripts.com/23723443.js"
          />
        </body>
      </Providers>
    </html>
  );
}
