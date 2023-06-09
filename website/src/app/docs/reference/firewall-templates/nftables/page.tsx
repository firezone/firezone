import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "nftables Firewall Template • Firezone Docs",
  description: "nftables Firewall Template for Firezone.",
};

export default function Page() {
  return <Content />;
}
