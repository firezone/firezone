import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Windows Client",
  description: "How to install and use the Firezone Windows Client.",
};

export default function Page() {
  return <Content />;
}
