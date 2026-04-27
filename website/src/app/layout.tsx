import { Metadata } from "next";
import { GoogleTagManager } from "@next/third-parties/google";
import { Roboto, Roboto_Mono, Roboto_Serif } from "next/font/google";
import Script from "next/script";

import "@/app/globals.css";
import "highlight.js/styles/a11y-dark.css";
import RootLayout from "@/components/RootLayout";
import Providers from "@/components/Providers";
import { DrawerProvider } from "@/components/Providers/DrawerProvider";

const roboto = Roboto({
  subsets: ["latin"],
  variable: "--font-roboto",
  display: "swap",
});
const robotoMono = Roboto_Mono({
  subsets: ["latin"],
  variable: "--font-roboto-mono",
  display: "swap",
});
const robotoSerif = Roboto_Serif({
  subsets: ["latin"],
  variable: "--font-roboto-serif",
  display: "swap",
});

const gtmId = "GTM-NBZ4CD98";

export const metadata: Metadata = {
  title: "WireGuard® for Enterprise • Firezone",
  description: "Open-source, zero-trust access platform built on WireGuard®",
};

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html
      lang="en"
      className={`${roboto.variable} ${robotoMono.variable} ${robotoSerif.variable}`}
    >
      <Script
        type="text/javascript"
        src="https://app.termly.io/resource-blocker/c4df1a31-22d9-4000-82e6-a86cbec0bba0?autoBlock=on"
      />
      {gtmId && <GoogleTagManager gtmId={gtmId} />}
      <body className="font-sans subpixel-antialiased text-neutral-900">
        <Providers>
          <DrawerProvider>
            <RootLayout>{children}</RootLayout>
          </DrawerProvider>
        </Providers>
      </body>
    </html>
  );
}
