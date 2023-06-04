import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • Install Firezone with Omnibus",
  description:
    "Install Firezone via our Omnibus deployment option to manage secure access to private networks and resources.",
};

export default function Page() {
  return <Content />;
}
