import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Omnibus Configuration",
  description: "Configuration of Omnibus-based deployments of Firezone.",
};

export default function Page() {
  return <Content />;
}
