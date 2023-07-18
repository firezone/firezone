import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Use Cases: Split Tunnel • Firezone Docs",
  description: "Use Cases: Split Tunnel",
};

export default function Page() {
  return <Content />;
}
