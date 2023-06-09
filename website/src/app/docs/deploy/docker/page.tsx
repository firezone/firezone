import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Install Firezone with Docker • Firezone Docs",
  description:
    "Install Firezone via Docker to manage secure remote access to private networks and resources.",
};

export default function Page() {
  return <Content />;
}
