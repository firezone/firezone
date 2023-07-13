import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "External Database • Firezone Docs",
  description: "Using an external database with Firezone.",
};

export default function Page() {
  return <Content />;
}
