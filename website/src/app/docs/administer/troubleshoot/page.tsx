import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Regenerate Secret Keys",
  description:
    "Troubleshoot common connectivity and configuration issues with Firezone's WireGuard®-based secure access platform.",
};

export default function Page() {
  return <Content />;
}
