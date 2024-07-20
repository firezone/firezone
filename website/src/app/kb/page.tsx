import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Docs • Firezone",
  description:
    "Learn how to deploy, manage, and scale Firezone for your organization.",
};

export default function Page() {
  return <Content />;
}
