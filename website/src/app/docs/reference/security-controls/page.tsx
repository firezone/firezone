import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Security Controls",
  description: "Firezone's security controls.",
};

export default function Page() {
  return <Content />;
}
