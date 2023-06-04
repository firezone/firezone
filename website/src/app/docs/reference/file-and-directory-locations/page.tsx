import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • File and Directory Locations",
  description: "File and directory locations for Firezone.",
};

export default function Page() {
  return <Content />;
}
