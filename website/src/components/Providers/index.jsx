"use client";
import { MixpanelProvider } from "react-mixpanel-browser";
import { HubspotProvider } from "next-hubspot";
import { GoogleAnalytics } from "@next/third-parties/google";

export default function Provider({ children }) {
  const token =
    process.env.NODE_ENV == "development"
      ? "313bdddc66b911f4afeb2c3242a78113"
      : "b0ab1d66424a27555ed45a27a4fd0cd2";
  const host = "https://t.firez.one";

  return (
    <MixpanelProvider
      token={token}
      config={{ api_host: host, record_sessions_percent: 5 }}
    >
      <HubspotProvider>{children}</HubspotProvider>
      <GoogleAnalytics gaId="AW-16577398140" />
    </MixpanelProvider>
  );
}
