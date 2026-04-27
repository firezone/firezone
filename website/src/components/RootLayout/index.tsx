import Link from "next/link";

import RootNavbar from "@/components/RootNavbar";
import Banner from "@/components/Banner";
import Script from "next/script";
import Footer from "@/components/Footer";
import Analytics from "@/components/Analytics";

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <>
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
        src="//js-na2.hs-scripts.com/23723443.js"
      />
      <Analytics />
    </>
  );
}
