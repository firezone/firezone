import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • nftables Firewall Template",
  description: "nftables Firewall Template for Firezone.",
};

export default function Page() {
  return <Content />;
}
