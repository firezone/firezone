import { Metadata } from "next";
import Content from "./readme.mdx";

export const metadata: Metadata = {
  title: "Restricted regions • Firezone Docs",
  description: "Learn more about the regions where Firezone is not available.",
};

export default function Page() {
  return <Content />;
}
