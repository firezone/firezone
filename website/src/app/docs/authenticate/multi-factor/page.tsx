import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Multi-factor Authentication • Firezone Docs",
  description:
    "Enforce multi-factor authentication with Firezone's WireGuard®-based secure access platform.",
};

export default function Page() {
  return <Content />;
}
