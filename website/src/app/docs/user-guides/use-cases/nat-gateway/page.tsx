import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Use Cases: Nat Gateway • Firezone Docs",
  description: "Use Cases: Nat Gateway",
};

export default function Page() {
  return <Content />;
}
