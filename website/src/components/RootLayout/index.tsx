import { Metadata } from "next";
import Link from "next/link";

import "@/app/globals.css";
import "highlight.js/styles/a11y-dark.css";
import RootNavbar from "@/components/RootNavbar";
import Banner from "@/components/Banner";
import Script from "next/script";
import Footer from "@/components/Footer";
import { HiArrowLongRight } from "react-icons/hi2";
import { usePathname, useSearchParams } from "next/navigation";
import Analytics from "@/components/Analytics";
import { Source_Sans_3, Manrope } from "next/font/google";
import { GoogleTagManager } from "@next/third-parties/google";

const source_sans_3 = Source_Sans_3({
  subsets: ["latin"],
  variable: "--font-source-sans-3",
  display: "swap",
});
const manrope = Manrope({
  subsets: ["latin"],
  variable: "--font-manrope",
  display: "swap",
});

const gtmId = process.env.NEXT_PUBLIC_GOOGLE_TAG_MANAGER_ID;

export const metadata: Metadata = {
  title: "WireGuard® for Enterprise • Firezone",
  description: "Open-source, zero-trust access platform built on WireGuard®",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className={`${source_sans_3.variable} ${manrope.variable}`}>
      <Script
        type="text/javascript"
        src="https://app.termly.io/resource-blocker/c4df1a31-22d9-4000-82e6-a86cbec0bba0?autoBlock=on"
      />
      {gtmId && <GoogleTagManager gtmId={gtmId} />}
      <body className={"subpixel-antialiased text-neutral-900 font-sans"}>
        <Banner active={false}>
          <p className="mx-auto text-center">
            Firezone 1.0 is here!{" "}
            <Link
              href="https://app.firezone.dev/sign_up"
              className="hover:underline inline-flex text-accent-500"
            >
              Sign up
            </Link>{" "}
            or{" "}
            <Link
              href="/kb/client-apps"
              className="hover:underline text-accent-500"
            >
              download
            </Link>{" "}
            now to get started.
          </p>
        </Banner>
        <RootNavbar />
        {children}
        <Footer />
        <Script
          strategy="lazyOnload"
          id="hs-script-loader"
          async
          defer
          src="//js.hs-scripts.com/23723443.js"
        />
        <Analytics />
      </body>
    </html>
  );
}
