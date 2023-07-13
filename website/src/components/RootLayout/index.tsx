import { Metadata } from "next";
import Link from "next/link";

import "@/app/globals.css";
import "highlight.js/styles/a11y-dark.css";
import RootNavbar from "@/components/RootNavbar";
import Script from "next/script";
import Banner from "@/components/Banner";
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
            <Banner active={false}>
              <p className="text-md font-medium text-center w-full text-neutral-200 dark:text-neutral-800">
                <strong>Firezone 1.0 is coming!</strong> Rebuilt from the ground
                up with a cloud dashboard, native clients, and more.{" "}
                <Link
                  href="/blog/announcing-1.0"
                  className="underline text-accent-500 dark:text-accent-800 hover:no-underline"
                >
                  Read the blogpost
                </Link>{" "}
                or{" "}
                <Link
                  href="/contact/1.0-early-access"
                  className="text-accent-500 dark:text-accent-800 underline hover:no-underline"
                >
                  request early access.
                </Link>
              </p>
            </Banner>
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
