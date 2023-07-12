import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Local Authentication • Firezone Docs",
  description: "Firezone can be upgraded with little or no downtime.",
};

export default function Page() {
  return <Content />;
}
