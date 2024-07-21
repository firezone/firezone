import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "iOS Client • Firezone Docs",
  description: "How to install and use the Firezone iOS Client.",
};

export default function Page() {
  return <Content />;
}
