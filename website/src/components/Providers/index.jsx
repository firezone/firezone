"use client";
import { MixpanelProvider } from "react-mixpanel-browser";
import { HubspotProvider } from "next-hubspot";
import { usePathname, useSearchParams } from "next/navigation";
import { useEffect } from "react";

export default function Provider({ children }) {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  useEffect(() => {}, [pathname, searchParams]);

  return (
    <>
      <MixpanelProvider
        token={process.env.NEXT_PUBLIC_MIXPANEL_TOKEN}
        config={{
          api_host: process.env.NEXT_PUBLIC_MIXPANEL_HOST,
          track_pageview: true,
        }}
      >
        <HubspotProvider>{children}</HubspotProvider>
      </MixpanelProvider>
    </>
  );
}
