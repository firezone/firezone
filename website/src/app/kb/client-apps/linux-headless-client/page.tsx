import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Linux Headless Client • Firezone Docs",
  description: "How to install and use the Firezone Linux headless client.",
};

export default function Page() {
  return <Content />;
}
