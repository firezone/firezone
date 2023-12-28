"use client";
import { MixpanelProvider } from "react-mixpanel-browser";
import { HubspotProvider } from "next-hubspot";

export default function Provider({ children }) {
  return (
    <MixpanelProvider
      token={process.env.NEXT_PUBLIC_MIXPANEL_TOKEN}
      config={{
        api_host: process.env.NEXT_PUBLIC_MIXPANEL_HOST,
        track_pageview: true,
      }}
    >
      <HubspotProvider>{children}</HubspotProvider>
    </MixpanelProvider>
  );
}
