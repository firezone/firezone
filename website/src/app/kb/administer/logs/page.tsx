import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Viewing Logs",
  description:
    "View Firezone logs for Clients, Gateways, and the Admin portal. Find log locations and learn how to export them — see the guide.",
};

export default function Page() {
  return <Content />;
}
