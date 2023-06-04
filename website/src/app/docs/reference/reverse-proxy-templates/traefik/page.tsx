import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Reverse Proxy Templates: Traefik",
  description: "Traefik Reverse Proxy Templates for Firezone.",
};

export default function Page() {
  return <Content />;
}
