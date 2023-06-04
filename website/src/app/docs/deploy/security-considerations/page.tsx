import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Security Considerations",
  description: "Security considerations for Firezone.",
};

export default function Page() {
  return <Content />;
}
