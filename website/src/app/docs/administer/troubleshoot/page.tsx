import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Troubleshoot • Firezone Docs",
  description:
    "Troubleshoot common connectivity and configuration issues with Firezone's WireGuard®-based secure access platform.",
};

export default function Page() {
  return <Content />;
}
