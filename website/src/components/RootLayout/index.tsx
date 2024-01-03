"use client";
import { Metadata } from "next";
import Link from "next/link";

import "@/app/globals.css";
import "highlight.js/styles/a11y-dark.css";
import RootNavbar from "@/components/RootNavbar";
import Script from "next/script";
import Banner from "@/components/Banner";
import Footer from "@/components/Footer";
import { Source_Sans_3 } from "next/font/google";
const source_sans_3 = Source_Sans_3({
  subsets: ["latin"],
  weight: ["200", "300", "400", "500", "600", "700", "800", "900"],
});
import { HiArrowLongRight } from "react-icons/hi2";
import { useMixpanel } from "react-mixpanel-browser";
import { usePathname, useSearchParams } from "next/navigation";
import { useEffect } from "react";

export const metadata: Metadata = {
  title: "WireGuard® for Enterprise • Firezone",
  description: "Open-source, zero-trust access platform built on WireGuard®",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const mixpanel = useMixpanel();

  useEffect(() => {
    if (!pathname) return;
    if (!mixpanel) return;

    let url = window.origin + pathname;
    if (searchParams.toString()) {
      url = url + `?${searchParams.toString()}`;
    }
    mixpanel.track("$mp_web_page_view", {
      $current_url: url,
    });
  }, [pathname, searchParams, mixpanel]);
  return (
    <html lang="en">
      <Script
        src="https://app.termly.io/embed.min.js"
        data-auto-block="on"
        data-website-uuid="c4df1a31-22d9-4000-82e6-a86cbec0bba0"
      ></Script>
      <body className={source_sans_3.className}>
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
    </html>
  );
}
