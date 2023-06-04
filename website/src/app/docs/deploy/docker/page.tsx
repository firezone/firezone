import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Install Firezone with Docker",
  description:
    "Install Firezone via Docker to manage secure remote access to private networks and resources.",
};

export default function Page() {
  return <Content />;
}
