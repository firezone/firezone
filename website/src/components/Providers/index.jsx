"use client";
import { HubspotProvider } from "next-hubspot";

export default function Provider({ children }) {
  return <HubspotProvider>{children}</HubspotProvider>;
}
