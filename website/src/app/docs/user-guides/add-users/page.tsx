import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • User Guides: Add Users",
  description: "Instructions for adding devices to Firezone.",
};

export default function Page() {
  return <Content />;
}
