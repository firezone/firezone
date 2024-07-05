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
          track_page_view: true,
          api_host: host,
          record_sessions_percent: 5,
        }}
      >
        {children}
      </MixpanelProvider>
    </HubspotProvider>
  );
}
