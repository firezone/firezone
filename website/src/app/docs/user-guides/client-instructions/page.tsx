import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • User Guides: Client Instructions",
  description: "Instructions for connecting clients to Firezone.",
};

export default function Page() {
  return <Content />;
}
