import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Deploy • Firezone Docs",
  description: "Firezone Documentation",
};

export default function Page() {
  return <Content />;
}
