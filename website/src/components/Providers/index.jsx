"use client";
import { MixpanelProvider } from "react-mixpanel-browser";
import { HubspotProvider } from "next-hubspot";

export default function Provider({ children }) {
  const token = "b0ab1d66424a27555ed45a27a4fd0cd2";
  const host = "t.firez.one";

  return (
    <>
      <MixpanelProvider token={token} config={{ api_host: host }}>
        <HubspotProvider>{children}</HubspotProvider>
      </MixpanelProvider>
    </>
  );
}
