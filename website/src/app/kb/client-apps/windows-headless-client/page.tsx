import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Windows Headless Client • Firezone Docs",
  description: "How to install and use the Firezone Windows headless client.",
};

export default function Page() {
  return <Content />;
}
