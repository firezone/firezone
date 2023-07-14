import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Environment Variables • Firezone Docs",
  description:
    "Environment variables for Docker-based deployments of Firezone.",
};

export default function Page() {
  return <Content />;
}
