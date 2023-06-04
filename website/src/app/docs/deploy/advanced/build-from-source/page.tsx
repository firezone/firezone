import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Build from source",
  description: "How to build Firezone from source.",
};

export default function Page() {
  return <Content />;
}
