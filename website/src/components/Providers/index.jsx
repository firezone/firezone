"use client";
import { MixpanelProvider } from "react-mixpanel-browser";
import { HubspotProvider } from "next-hubspot";

export default function Provider({ children }) {
  const mpToken = process.env.NEXT_PUBLIC_MIXPANEL_TOKEN;
  const host = "https://t.firez.one";

  return (
    <HubspotProvider>
      <MixpanelProvider
        token={mpToken}
        config={{
          // This doesn't work for the website because page views happen client-side.
          // We handle this in the Mixpanel component with useSearchParams instead.
          // track_page_view: true,
          api_host: host,
          record_sessions_percent: 5,
        }}
      >
        {children}
      </MixpanelProvider>
    </HubspotProvider>
  );
}
