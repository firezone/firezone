import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Reference",
  description: "Firezone documentation reference.",
};

export default function Page() {
  return <Content />;
}
