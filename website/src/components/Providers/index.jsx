"use client";
import { MixpanelProvider } from "react-mixpanel-browser";
import { HubspotProvider } from "next-hubspot";
import { GoogleAnalytics } from "@next/third-parties/google";

export default function Provider({ children }) {
  const mpToken = process.env.NEXT_PUBLIC_MIXPANEL_TOKEN;
  const gaId = process.env.NEXT_PUBLIC_GOOGLE_ANALYTICS_ID;
  const host = "https://t.firez.one";

  return (
    <>
      <MixpanelProvider
        token={mpToken}
        config={{ api_host: host, record_sessions_percent: 5 }}
      />
      <HubspotProvider>{children}</HubspotProvider>
      <GoogleAnalytics gaId />
    </>
  );
}
