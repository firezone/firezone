import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: { absolute: "Firezone Documentation — Setup & Guides" },
  description:
    "Learn how to deploy, configure, and scale Firezone. Step-by-step guides for clients, gateways, identity providers, and zero trust policies.",
};

export default function Page() {
  return <Content />;
}
