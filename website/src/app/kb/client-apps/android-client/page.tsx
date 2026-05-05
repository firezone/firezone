import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Android & ChromeOS Client",
  description: "How to install and use the Firezone Android & ChromeOS Client.",
};

export default function Page() {
  return <Content />;
}
