import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Use Cases: Reverse Tunnel • Firezone Docs",
  description: "Use Cases: Reverse Tunnel",
};

export default function Page() {
  return <Content />;
}
