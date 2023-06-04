import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Supported platforms for Omnibus",
  description: "Supported platforms for Omnibus-based deployments of Firezone.",
};

export default function Page() {
  return <Content />;
}
