import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • External database",
  description: "Using an external database with Firezone.",
};

export default function Page() {
  return <Content />;
}
