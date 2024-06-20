import { Metadata } from "next";
import Link from "next/link";

import "@/app/globals.css";
import "highlight.js/styles/a11y-dark.css";
import RootNavbar from "@/components/RootNavbar";
import Banner from "@/components/Banner";
import Script from "next/script";
import Footer from "@/components/Footer";
import { Source_Sans_3 } from "next/font/google";
const source_sans_3 = Source_Sans_3({
  subsets: ["latin"],
  weight: ["200", "300", "400", "500", "600", "700", "800", "900"],
});
import { HiArrowLongRight } from "react-icons/hi2";
import { usePathname, useSearchParams } from "next/navigation";
import { Mixpanel, GoogleAds, LinkedInInsights } from "@/components/Analytics";

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
    <html lang="en">
      <Script
        type="text/javascript"
        src="https://app.termly.io/resource-blocker/c4df1a31-22d9-4000-82e6-a86cbec0bba0?autoBlock=on"
      />
      <Mixpanel />
      <body className={"text-neutral-900 " + source_sans_3.className}>
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
              href="/kb/user-guides"
              className="hover:underline text-accent-500"
            >
              download
            </Link>{" "}
            now to get started.
          </p>
        </Banner>
        <div className="min-h-screen h-auto antialiased">
          <RootNavbar />
          {children}
          <Footer />
        </div>
        <Script
          strategy="lazyOnload"
          id="hs-script-loader"
          async
          defer
          src="//js.hs-scripts.com/23723443.js"
        />
        <GoogleAds />
        <LinkedInInsights />
      </body>
    </html>
  );
}
