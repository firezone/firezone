import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Resources • Firezone Docs",
  description: "Firezone Documentation",
};

export default function Page() {
  return <Content />;
}
