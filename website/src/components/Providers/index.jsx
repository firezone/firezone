"use client";
import { MixpanelProvider, useMixpanel } from "react-mixpanel-browser";
import { HubspotProvider } from "next-hubspot";
import { usePathname, useSearchParams } from "next/navigation";
import { useEffect } from "react";

export default function Provider({ children }) {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const mixpanel = useMixpanel();

  useEffect(() => {
    if (!pathname) return;
    if (!mixpanel) {
      console.log("Mixpanel uninitialized!");
      return;
    }

    let url = window.origin + pathname;
    if (searchParams.toString()) {
      url = url + `?${searchParams.toString()}`;
    }
    mixpanel.track("$mp_web_page_view", {
      $current_url: url,
    });
  });

  return (
    <>
      <MixpanelProvider
        token={process.env.NEXT_PUBLIC_MIXPANEL_TOKEN}
        config={{ api_host: process.env.NEXT_PUBLIC_MIXPANEL_HOST }}
      >
        <HubspotProvider>{children}</HubspotProvider>
      </MixpanelProvider>
    </>
  );
}
