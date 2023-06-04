import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Use Cases",
  description: "Use Cases for Firezone.",
};

export default function Page() {
  return <Content />;
}
