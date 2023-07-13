import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Supported Platforms for Docker • Firezone Docs",
  description: "Docker supported platforms for Firezone.",
};

export default function Page() {
  return <Content />;
}
