import Content from "./readme.mdx";
import { Metadata } from "next";

export const metadata: Metadata = {
  title: "Firezone Docs • REST API",
  description: "Firezone's REST API",
};

export default function Page() {
  return <Content />;
}
