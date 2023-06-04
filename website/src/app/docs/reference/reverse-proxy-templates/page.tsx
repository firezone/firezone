import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Reverse Proxy Templates",
  description: "Reverse Proxy Templates for Firezone.",
};

export default function Page() {
  return <Content />;
}
