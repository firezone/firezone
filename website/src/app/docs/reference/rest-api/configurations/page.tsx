import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Firewall Templates",
  description: "Firezone firewall templates.",
};

export default function Page() {
  return <Content />;
}
