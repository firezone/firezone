import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Configure",
  description: "Documentation for configuring Firezone.",
};

export default function Page() {
  return <Content />;
}
