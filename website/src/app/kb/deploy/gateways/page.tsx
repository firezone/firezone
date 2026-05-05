import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Gateways",
  description:
    "Deploy Firezone Gateways to bridge Clients to Resources in a Site. Set up your access infrastructure — follow the Gateway guide.",
};

export default function Page() {
  return <Content />;
}
