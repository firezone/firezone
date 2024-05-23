"use client";
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
import { useMixpanel } from "react-mixpanel-browser";
import { usePathname, useSearchParams } from "next/navigation";
import { useEffect, Suspense } from "react";

export const metadata: Metadata = {
  title: "WireGuard® for Enterprise • Firezone",
  description: "Open-source, zero-trust access platform built on WireGuard®",
};

interface HubSpotSubmittedFormData {
  type: string;
  eventName: string;
  redirectUrl: string;
  conversionId: string;
  formGuid: string;
  submissionValues: {
    [key: string]: string;
  };
}

function Mixpanel() {
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

    const handleMessage = (event: MessageEvent) => {
      if (event.data.type === 'hsFormCallback' && event.data.eventName === 'onFormSubmitted') {
        const formData: HubSpotSubmittedFormData = event.data.data;
        if (!formData || !formData.formGuid || !formData.submissionValues) {
          console.error("Missing form data:", formData);
          return;
        }

        if (formData.submissionValues.email && formData.submissionValues.firstname && formData.submissionValues.lastname) {
          mixpanel.people.set({
            $email: formData.submissionValues.email,
            $first_name: formData.submissionValues.firstname,
            $last_name: formData.submissionValues.lastname
          });

          mixpanel.track("HubSpot Form Submitted", {
            formId: formData.formGuid,
            conversionId: formData.conversionId,
          });
        }
      }
    };

    window.addEventListener('message', handleMessage);

    return () => {
      window.removeEventListener('message', handleMessage);
    };
  }, [pathname, searchParams, mixpanel]);

  return null;
}

function GoogleAds() {
  const trackingId = process.env.NODE_ENV == "development" ? null : "AW-16577398140";

  useEffect(() => {
    (window as any).dataLayer = (window as any).dataLayer || [];
    const gtag: (...args: any[]) => void = (...args) => {
      (window as any).dataLayer.push(args);
    };

    const addGoogleScript = () => {
      if (!trackingId) return;

      const scriptTag = document.createElement('script');
      scriptTag.src = `https://www.googletagmanager.com/gtag/js?id=${trackingId}`;
      scriptTag.async = true;
      document.head.appendChild(scriptTag);

      scriptTag.onload = () => {
        gtag('js', new Date());
        gtag('config', trackingId);
      };
    };

    addGoogleScript();

    const handleMessage = (event: MessageEvent) => {
      if (event.data.type === 'hsFormCallback' && event.data.eventName === 'onFormSubmitted') {
        const formData: HubSpotSubmittedFormData = event.data.data;
        if (!formData || !formData.formGuid || !formData.submissionValues) {
          console.error("Missing form data:", formData);
          return;
        }

        gtag('event', 'conversion', {
          'send_to': 'AW-16577398140/1wX_CNmzg7MZEPyK3OA9',
          'value': Number(formData.submissionValues['0-2/numberofemployees']) * 5,
          'currency': 'USD',
        });
      }
    };

    window.addEventListener('message', handleMessage);

    return () => {
      window.removeEventListener('message', handleMessage);
    };
  }, [trackingId]);

  return null;
}

function LinkedInInsights() {
  const linkedInPartnerId = "6200852";

  useEffect(() => {
    const winAny = window as any;
    winAny._linkedin_data_partner_ids = winAny._linkedin_data_partner_ids || [];
    winAny._linkedin_data_partner_ids.push(linkedInPartnerId);

    const initializeLintrk = () => {
      if (winAny.lintrk) return;

      winAny.lintrk = function (a: any, b: any) {
        (winAny.lintrk.q = winAny.lintrk.q || []).push([a, b]);
      };

      const s = document.getElementsByTagName("script")[0];
      const b = document.createElement("script");
      b.type = "text/javascript";
      b.async = true;
      b.src = "https://snap.licdn.com/li.lms-analytics/insight.min.js";
      if (s && s.parentNode) {
        s.parentNode.insertBefore(b, s);
      }
    };

    initializeLintrk();

    const handleMessage = (event: MessageEvent) => {
      if (event.data.type === 'hsFormCallback' && event.data.eventName === 'onFormSubmitted') {
        const formData: HubSpotSubmittedFormData = event.data.data;
        if (!formData || !formData.formGuid || !formData.submissionValues) {
          console.error("Missing form data:", formData);
          return;
        }

        (window as any).lintrk('track', { conversion_id: 16519956 });
      }
    };

    window.addEventListener('message', handleMessage);

    return () => {
      window.removeEventListener('message', handleMessage);
    };
  }, [linkedInPartnerId]);

  return null;
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <Script
        src="https://app.termly.io/embed.min.js"
        data-auto-block="off"
        data-website-uuid="c4df1a31-22d9-4000-82e6-a86cbec0bba0"
      ></Script>
      <Suspense>
        <Mixpanel />
        <GoogleAds />
        <LinkedInInsights />
      </Suspense>
      <body className={source_sans_3.className}>
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
      </body>
    </html>
  );
}
