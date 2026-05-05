import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "macOS Client",
  description: "How to install and use the Firezone macOS Client.",
};

export default function Page() {
  return <Content />;
}
