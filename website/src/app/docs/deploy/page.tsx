import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Deploy Firezone • Firezone Docs",
  description:
    "Install Firezone's WireGuard®-based secure access platform on a support host using our Docker (recommended) or Omnibus deployment methods.",
};

export default function Page() {
  return <Content />;
}
