import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Build From Source • Firezone Docs",
  description: "How to build Firezone from source.",
};

export default function Page() {
  return <Content />;
}
