import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "User Guides: Add Devices • Firezone Docs",
  description: "Instructions for adding devices to Firezone.",
};

export default function Page() {
  return <Content />;
}
