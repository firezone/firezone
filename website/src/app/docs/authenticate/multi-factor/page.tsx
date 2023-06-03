import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Multi-factor Authentication",
  description:
    "Enforce multi-factor authentication with Firezone's WireGuard®-based secure access platform.",
};

export default function Page() {
  return <Content />;
}
