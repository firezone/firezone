import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "File and Directory Locations • Firezone Docs",
  description: "File and directory locations for Firezone.",
};

export default function Page() {
  return <Content />;
}
