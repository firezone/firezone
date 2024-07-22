import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Administer • Firezone Docs",
  description: "Learn how to manage your Firezone deployment day-to-day.",
};

export default function Page() {
  return <Content />;
}
