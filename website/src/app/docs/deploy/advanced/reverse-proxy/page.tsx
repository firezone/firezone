import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Custom Reverse Proxy • Firezone Docs",
  description: "Using a custom reverse proxy with Firezone.",
};

export default function Page() {
  return <Content />;
}
