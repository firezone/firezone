import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Architecture: Security Controls • Firezone Docs",
  description: "How we keep your data secure at rest and in transit.",
};

export default function Page() {
  return <Content />;
}
