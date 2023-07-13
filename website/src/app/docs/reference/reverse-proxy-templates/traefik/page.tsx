import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Reverse Proxy Templates: Traefik • Firezone Docs",
  description: "Traefik Reverse Proxy Templates for Firezone.",
};

export default function Page() {
  return <Content />;
}
