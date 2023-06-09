import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Support Platforms for Omnibus • Firezone Docs",
  description: "Supported platforms for Omnibus-based deployments of Firezone.",
};

export default function Page() {
  return <Content />;
}
