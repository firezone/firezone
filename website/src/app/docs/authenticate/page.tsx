import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Authenticate • Firezone Docs",
  description: "Authenticating with Firezone.",
};

export default function Page() {
  return <Content />;
}
