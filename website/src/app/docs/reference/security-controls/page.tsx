import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Security Controls • Firezone Docs",
  description: "Firezone's security controls.",
};

export default function Page() {
  return <Content />;
}
