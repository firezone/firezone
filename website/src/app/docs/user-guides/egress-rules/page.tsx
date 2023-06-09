import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "User Guides: Egress Rules • Firezone Docs",
  description: "User Guides: Egress Rules",
};

export default function Page() {
  return <Content />;
}
