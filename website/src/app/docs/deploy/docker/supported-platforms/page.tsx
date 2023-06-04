import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Docker supported platforms",
  description: "Docker supported platforms for Firezone.",
};

export default function Page() {
  return <Content />;
}
