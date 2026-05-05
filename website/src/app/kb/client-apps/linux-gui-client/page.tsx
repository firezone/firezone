import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Linux GUI Client",
  description: "How to install and use the Firezone Linux GUI Client.",
};

export default function Page() {
  return <Content />;
}
