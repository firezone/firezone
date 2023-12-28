"use client";
import { MixpanelProvider } from "react-mixpanel-browser";
import { HubspotProvider } from "next-hubspot";

export default function Provider({ children }) {
  const token = process.env.NEXT_PUBLIC_MIXPANEL_TOKEN;
  const host = process.env.NEXT_PUBLIC_MIXPANEL_HOST;

  return (
    <>
      <MixpanelProvider token={token} config={{ api_host: host }}>
        <HubspotProvider>{children}</HubspotProvider>
      </MixpanelProvider>
    </>
  );
}
