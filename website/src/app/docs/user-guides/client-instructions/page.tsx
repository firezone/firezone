import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "User Guides: Client Instructions • Firezone Docs",
  description: "Instructions for connecting clients to Firezone.",
};

export default function Page() {
  return <Content />;
}
