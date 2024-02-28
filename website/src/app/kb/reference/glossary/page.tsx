import { Metadata } from "next";
import Content from "./readme.mdx";

export const metadata: Metadata = {
  title: "Glossary • Firezone Docs",
  description: "Learn about the terms used in Firezone.",
};

export default function Page() {
  return <Content />;
}
