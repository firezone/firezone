import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Docker Compose • Firezone Docs",
  description: "Learn how to deploy Firezone Gateways with Docker Compose",
};

export default function Page() {
  return <Content />;
}
