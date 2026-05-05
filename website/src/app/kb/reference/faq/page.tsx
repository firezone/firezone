import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "FAQ",
  description:
    "Read answers to frequently asked questions about Firezone — pricing, deployment, security, supported platforms, and more.",
};

export default function Page() {
  return <Content />;
}
