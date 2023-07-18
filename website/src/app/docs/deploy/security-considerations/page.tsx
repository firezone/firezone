import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Security Considerations • Firezone Docs",
  description: "Security considerations for Firezone.",
};

export default function Page() {
  return <Content />;
}
