import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Advanced deployment topics",
  description: "Advanced deployment options for Firezone.",
};

export default function Page() {
  return <Content />;
}
